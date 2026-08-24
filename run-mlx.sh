#!/usr/bin/env bash
# Локальный инференс Gemma 4 на Apple Silicon через MLX.
#
# Почему MLX, а не llama.cpp: на длинном контексте Metal-ядро llama.cpp для
# глобальных attention-слоёв Gemma 4 (MQA, одна KV-голова на 16 Q-голов)
# выдаёт 0.51 TFLOPS против 3.82 TFLOPS на матричных умножениях. На 123K
# токенов это 76 минут префилла против 6 у MLX. Флагами не лечится.
#
# Две модели решают разные задачи:
#   E4B — 443 tok/s префилла, но на 16 ГБ держит примерно 80K контекста;
#   12B — 83 tok/s, зато полные 128K и заметно выше качество.
# Парадокс с памятью: E4B требует БОЛЬШЕ, чем 12B, потому что её
# Per-Layer Embeddings весят на 0.5 ГБ больше, чем экономит меньший KV.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$SCRIPT_DIR/.venv-mlx/bin/python"

# Сервер не поддерживает алиасы: поле "model" в запросе должно быть путём к
# весам, и при незнакомом значении он лезет на HuggingFace. Держим короткие
# симлинки в корне проекта и запускаем сервер через них — тогда клиент шлёт
# "gemma-e4b", путь совпадает с загруженным, и перезагрузки весов не будет.
MODEL_DIR="models/mlx-e4b-qat-4bit"
MODEL_REF="gemma-e4b"
MODEL_NAME="Gemma 4 E4B (QAT 4-bit)"
SAFE_CTX="80K"
# Шаг префилла определяет пик памяти. У E4B оптимум на 512: мельче уже не
# снижает пик (256 даёт минус 0.2 ГБ ценой 3% скорости). У 12B при 512 пик
# 12.43 ГБ — слишком близко к потолку, поэтому 256 и пик 11.75 ГБ.
PREFILL_STEP="${PREFILL_STEP:-}"
PORT="${PORT:-8080}"
WITH_PROXY=1

usage() {
    cat <<'EOF'
Использование: ./run-mlx.sh [опции]

    --12b            12B вместо E4B: втрое медленнее префилл, но полные
                     128K контекста и выше качество
    --no-proxy       не поднимать llm-proxy.mjs на :8081
    --step N         шаг префилла (по умолчанию 512 для E4B, 256 для 12B)
    --port N         порт сервера (по умолчанию 8080)

Переменные окружения:
    PORT, PREFILL_STEP, MLX_CACHE_GB (по умолчанию 0.3)

Замеры на M1 Pro, документ с проверкой на удержание фактов из начала
(потолок GPU на машине с 16 ГБ — 12.5 ГБ, это 78% от RAM):

    модель  контекст  префилл     время   пик памяти
    E4B     80K       443 tok/s   3.0 мин  11.69 ГБ   <- запас 6.5%
    E4B     96K       422 tok/s   3.7 мин  12.49 ГБ   <- на грани
    E4B     123K      374 tok/s   5.5 мин  12.97 ГБ   <- не влезает
    12B     123K       83 tok/s    25 мин  11.75 ГБ   <- запас 6.4%
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --12b)
            MODEL_DIR="models/mlx-4bit"
            MODEL_REF="gemma-12b"
            MODEL_NAME="Gemma 4 12B (QAT 4-bit)"
            SAFE_CTX="128K"
            shift ;;
        --no-proxy) WITH_PROXY=0; shift ;;
        --step)     PREFILL_STEP="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage; exit 1 ;;
    esac
done

# Шаг не задан ни флагом, ни окружением — берём оптимум для выбранной модели.
if [[ -z "$PREFILL_STEP" ]]; then
    if [[ "$MODEL_NAME" == *12B* ]]; then PREFILL_STEP=256; else PREFILL_STEP=512; fi
fi

cd "$SCRIPT_DIR"   # пути моделей и симлинки задаются относительно корня проекта

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "Модель не найдена: $SCRIPT_DIR/$MODEL_DIR" >&2
    echo "" >&2
    if [[ "$MODEL_NAME" == *E4B* ]]; then
        echo "Скачать:" >&2
        echo "  ./.venv-mlx/bin/hf download mlx-community/gemma-4-E4B-it-qat-4bit \\" >&2
        echo "      --local-dir models/mlx-e4b-qat-4bit" >&2
    else
        echo "Ожидался каталог с MLX-весами 12B." >&2
    fi
    exit 1
fi

ln -sfn "$MODEL_DIR" "$MODEL_REF"

if [[ ! -x "$PY" ]]; then
    echo "Не найден Python окружения MLX: $PY" >&2
    exit 1
fi

cleanup() {
    echo ""
    echo "Останавливаю..."
    [[ -n "${PROXY_PID:-}" ]] && kill "$PROXY_PID" 2>/dev/null || true
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Запускаю $MODEL_NAME на Metal..."
echo "API:   http://localhost:$PORT/v1"
echo "model: \"$MODEL_REF\"  (это значение поля model в запросах)"
echo "Шаг префилла: $PREFILL_STEP   Рекомендуемый максимум контекста: $SAFE_CTX"
echo ""

MLX_CACHE_GB="${MLX_CACHE_GB:-0.3}" "$PY" "$SCRIPT_DIR/mlx_server_tuned.py" \
    --model "$MODEL_REF" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --prefill-step-size "$PREFILL_STEP" \
    --log-level INFO &
SERVER_PID=$!

echo "Жду готовности сервера (загрузка весов занимает ~30 секунд)..."
until curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Сервер не поднялся — смотрите вывод выше." >&2
        exit 1
    fi
    sleep 0.5
done
echo "Сервер готов."

if [[ $WITH_PROXY -eq 1 ]]; then
    node "$SCRIPT_DIR/llm-proxy.mjs" &
    PROXY_PID=$!
    echo "Прокси статистики на :8081 (cat ~/.llm-stats)"
fi

echo ""
wait "$SERVER_PID"
