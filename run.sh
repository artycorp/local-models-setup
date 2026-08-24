#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="$SCRIPT_DIR/models/google_gemma-4-26B-A4B-it-Q4_K_M.gguf"
SERVER="$SCRIPT_DIR/llama.cpp/build/bin/llama-server"

if [[ ! -f "$MODEL" ]]; then
    echo "Error: model not found at $MODEL"
    echo "Download still in progress? Check: ls -lah $SCRIPT_DIR/models/"
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

echo "Starting Gemma 4 26B (128K context) on Metal..."
echo "API: http://localhost:8080/v1   Chat UI: http://localhost:8080"
echo ""

"$SERVER" \
    --model "$MODEL" \
    --ctx-size 131072 \
    --n-gpu-layers 999 \
    --flash-attn 1 \
    --cache-type-k q4_0 \
    --cache-type-v q4_0 \
    --batch-size 512 \
    --ubatch-size 512 \
    --reasoning off \
    --jinja \
    --temp 0.7 \
    --top-p 0.8 \
    --top-k 20 \
    --presence-penalty 0.0 \
    --repeat-penalty 1.0 \
    --no-mmap \
    --host 127.0.0.1 \
    --port 8080 &
SERVER_PID=$!

echo "Waiting for llamacpp to be ready..."
until curl -sf http://localhost:8080/health >/dev/null 2>&1; do
    sleep 0.5
done

node "$SCRIPT_DIR/llm-proxy.mjs" &
PROXY_PID=$!

echo "Stats proxy ready on :8081"
echo "Stats: cat ~/.llm-stats"
echo ""

wait "$SERVER_PID"
