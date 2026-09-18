#!/usr/bin/env bash
# Qwen3.8-27B (MLX 4-bit) via Rapid-MLX, tuned for use as a pi coding agent.
#
#   ./run-rapid-qwen.sh          foreground (Ctrl-C stops)
#   ./run-rapid-qwen.sh --bg     background, log in /tmp/rapid-qwen.log
#   ./run-rapid-qwen.sh --stop
#
# Why these flags:
#   --no-thinking            answers immediately instead of a "Thinking Notes" block
#   --enable-auto-tool-choice
#   --tool-call-parser auto  pi works through tools (read/bash/edit/write); without a
#                            parser the model writes calls as plain text and the agent stalls
set -euo pipefail

MODEL_DIR="${QWEN_DIR:-$HOME/models/Qwen3.8-27B-4bit-MLX}"
NAME="${QWEN_NAME:-qwen3.8-27b}"
PORT="${PORT:-8000}"
PARSER="${TOOL_PARSER:-auto}"   # fallbacks: qwen3_coder, qwen3_xml
LOG=/tmp/rapid-qwen.log

case "${1:-}" in
    --stop) pkill -f "rapid-mlx serve" && echo "stopped" || echo "not running"; exit 0 ;;
    --bg|"") ;;
    *) echo "Usage: $0 [--bg|--stop]" >&2; exit 1 ;;
esac

[[ -d "$MODEL_DIR" ]] || { echo "Model not found: $MODEL_DIR" >&2; exit 1; }
command -v rapid-mlx >/dev/null || { echo "Run: brew install rapid-mlx" >&2; exit 1; }

if curl -sf "localhost:$PORT/health" >/dev/null 2>&1; then
    echo "already running on :$PORT"; exit 0
fi

ARGS=(serve "$MODEL_DIR" --served-model-name "$NAME" --port "$PORT"
      --no-thinking --enable-auto-tool-choice --tool-call-parser "$PARSER"
      # Qwen3.8 is hybrid (non-trimmable cache): keep stable-prefix entries and
      # pin the system prompt so agent turns only prefill the new suffix.
      --hybrid-cache-entries 8 --pin-system-prompt)

if [[ "${1:-}" == "--bg" ]]; then
    nohup rapid-mlx "${ARGS[@]}" >"$LOG" 2>&1 &
    for _ in $(seq 1 90); do
        curl -sf "localhost:$PORT/health" >/dev/null 2>&1 && { echo "ready: http://127.0.0.1:$PORT/v1 (model $NAME)"; exit 0; }
        sleep 2
    done
    echo "did not become ready — see $LOG" >&2; exit 1
fi
exec rapid-mlx "${ARGS[@]}"
