#!/usr/bin/env bash
# Проверка конфигурации под потолок 16 ГБ на машине с бо́льшим объёмом RAM.
#
# macOS отдаёт GPU долю физической памяти (iogpu.wired_limit_mb, 0 = ~78% RAM).
# Выставив лимит вручную, мы получаем на 32-гигабайтной машине те же условия,
# в которых окажется 16-гигабайтный ноутбук: 16 ГБ * 0.78 ≈ 12.5 ГБ, минус
# запас на систему -> 12800 МБ (см. mx.device_info() в CLAUDE.md: реальный потолок 78% RAM, не 75%).
#
# Скрипт ставит лимит, гоняет заданную команду и ВСЕГДА возвращает лимит
# обратно в 0, даже если команду прервали.
set -euo pipefail

LIMIT_MB="${LIMIT_MB:-12800}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -eq 0 ]]; then
    cat <<EOF
Использование: sudo ./check-16gb.sh <команда> [аргументы...]

Примеры:
    sudo ./check-16gb.sh ./run-mlx.sh
    sudo LIMIT_MB=8000 ./check-16gb.sh ./run-mlx.sh --12b

Текущий лимит: $(sysctl -n iogpu.wired_limit_mb) МБ (0 = по умолчанию, ~78% RAM)
Физической памяти: $(( $(sysctl -n hw.memsize) / 1024 / 1024 )) МБ
EOF
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Нужен sudo: sysctl iogpu.wired_limit_mb пишется только от root." >&2
    echo "Запустите: sudo $0 $*" >&2
    exit 1
fi

restore() {
    echo ""
    echo "Возвращаю iogpu.wired_limit_mb в 0 (значение по умолчанию)..."
    sysctl -w iogpu.wired_limit_mb=0 >/dev/null
    echo "Готово: $(sysctl -n iogpu.wired_limit_mb)"
}
trap restore EXIT INT TERM

echo "Ставлю потолок GPU в $LIMIT_MB МБ (эмуляция машины на 16 ГБ)..."
sysctl -w iogpu.wired_limit_mb="$LIMIT_MB"
echo ""

# Снимок счётчиков подкачки до запуска: рост swapins/swapouts во время
# прогона означает, что конфигурация в лимит не уложилась.
before=$(vm_stat | awk '/Swapins|Swapouts/ {gsub(/\./,"",$NF); print $NF}' | paste -sd' ' -)

set +e
"$@"
rc=$?
set -e

after=$(vm_stat | awk '/Swapins|Swapouts/ {gsub(/\./,"",$NF); print $NF}' | paste -sd' ' -)

echo ""
echo "=== подкачка за время прогона ==="
paste <(echo "$before" | tr ' ' '\n') <(echo "$after" | tr ' ' '\n') \
    | awk 'BEGIN{n["1"]="swapins";n["2"]="swapouts"}
           {printf "%-10s %s -> %s  (дельта %d)\n", n[NR], $1, $2, $2-$1}'
echo ""
echo "Ненулевая дельта = система вытесняла страницы на диск: конфигурация"
echo "в $LIMIT_MB МБ не уложилась, несмотря на то что процесс не упал."

exit $rc
