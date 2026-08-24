#!/usr/bin/env bash
# Local Gemma 4 inference on Apple Silicon via MLX.
#
# Why MLX instead of llama.cpp: on long context, llama.cpp's Metal kernel
# for Gemma 4's global attention layers (MQA, one KV head per 16 Q heads)
# delivers 0.51 TFLOPS against 3.82 TFLOPS on matrix multiplies. At 123K
# tokens that's 76 minutes of prefill versus 6 for MLX. Flags don't fix it.
#
# The two models solve different problems:
#   E4B — 443 tok/s prefill, but on 16 GB holds only about 80K context;
#   12B — 83 tok/s, but the full 128K and noticeably higher quality.
# The memory paradox: E4B needs MORE memory than 12B, because its
# Per-Layer Embeddings weigh 0.5 GB more than its smaller KV cache saves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$SCRIPT_DIR/.venv-mlx/bin/python"

# The server doesn't support aliases: the "model" field in a request must
# be a path to the weights, and an unrecognized value sends it to
# HuggingFace. We keep short symlinks in the project root and launch the
# server through them — then the client sends "gemma-e4b", the path
# matches what's loaded, and the weights never get reloaded.
MODEL_DIR="models/mlx-e4b-qat-4bit"
MODEL_REF="gemma-e4b"
MODEL_NAME="Gemma 4 E4B (QAT 4-bit)"
SAFE_CTX="80K"
# The prefill step size drives the peak memory. E4B's optimum is 512:
# going smaller doesn't lower the peak further (256 saves 0.2 GB at the
# cost of 3% speed). 12B peaks at 12.43 GB with 512 — too close to the
# ceiling, so it uses 256 and peaks at 11.75 GB instead.
PREFILL_STEP="${PREFILL_STEP:-}"
PORT="${PORT:-8080}"
WITH_PROXY=1

usage() {
    cat <<'EOF'
Usage: ./run-mlx.sh [options]

    --12b            12B instead of E4B: prefill three times slower, but
                     full 128K context and higher quality
    --no-proxy       don't start llm-proxy.mjs on :8081
    --step N         prefill step size (default 512 for E4B, 256 for 12B)
    --port N         server port (default 8080)

Environment variables:
    PORT, PREFILL_STEP, MLX_CACHE_GB (default 0.3)

Measurements on M1 Pro, a document tested for fact retention from the start
(GPU ceiling on a 16 GB machine — 12.5 GB, that's 78% of RAM):

    model   context   prefill     time     peak memory
    E4B     80K       443 tok/s   3.0 min  11.69 GB   <- 6.5% headroom
    E4B     96K       422 tok/s   3.7 min  12.49 GB   <- cutting it close
    E4B     123K      374 tok/s   5.5 min  12.97 GB   <- doesn't fit
    12B     123K       83 tok/s    25 min  11.75 GB   <- 6.4% headroom
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
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# No step given via flag or environment — use the optimum for the chosen model.
if [[ -z "$PREFILL_STEP" ]]; then
    if [[ "$MODEL_NAME" == *12B* ]]; then PREFILL_STEP=256; else PREFILL_STEP=512; fi
fi

cd "$SCRIPT_DIR"   # model paths and symlinks are relative to the project root

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "Model not found: $SCRIPT_DIR/$MODEL_DIR" >&2
    echo "" >&2
    if [[ "$MODEL_NAME" == *E4B* ]]; then
        echo "Download it:" >&2
        echo "  ./.venv-mlx/bin/hf download mlx-community/gemma-4-E4B-it-qat-4bit \\" >&2
        echo "      --local-dir models/mlx-e4b-qat-4bit" >&2
    else
        echo "Expected a directory with the 12B MLX weights." >&2
    fi
    exit 1
fi

ln -sfn "$MODEL_DIR" "$MODEL_REF"

if [[ ! -x "$PY" ]]; then
    echo "MLX environment Python not found: $PY" >&2
    exit 1
fi

cleanup() {
    echo ""
    echo "Stopping..."
    [[ -n "${PROXY_PID:-}" ]] && kill "$PROXY_PID" 2>/dev/null || true
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Starting $MODEL_NAME on Metal..."
echo "API:   http://localhost:$PORT/v1"
echo "model: \"$MODEL_REF\"  (this is the value of the model field in requests)"
echo "Prefill step: $PREFILL_STEP   Recommended context ceiling: $SAFE_CTX"
echo ""

MLX_CACHE_GB="${MLX_CACHE_GB:-0.3}" "$PY" "$SCRIPT_DIR/mlx_server_tuned.py" \
    --model "$MODEL_REF" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --prefill-step-size "$PREFILL_STEP" \
    --log-level INFO &
SERVER_PID=$!

echo "Waiting for the server to become ready (loading weights takes ~30s)..."
until curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Server failed to start — see output above." >&2
        exit 1
    fi
    sleep 0.5
done
echo "Server ready."

if [[ $WITH_PROXY -eq 1 ]]; then
    node "$SCRIPT_DIR/llm-proxy.mjs" &
    PROXY_PID=$!
    echo "Stats proxy on :8081 (cat ~/.llm-stats)"
fi

echo ""
wait "$SERVER_PID"
