#!/usr/bin/env bash
# Start the Rapid-MLX server if it isn't up, then open pi on Qwen3.8-27B.
#
# Lean by default: measured on this setup, pi's prompt is 1.7K tokens bare,
# but 15.5K with ~/.claude/skills (+4.7K) and the pi-subagents/pi-web-access
# extensions (+9.1K, 7 extra tools). Prefill here is ~50 tok/s, so 15K cold
# is ~5 min, and any change to the prefix throws the KV cache away.
#   PI_FULL=1 ./pi-qwen.sh   keep skills + extensions (bigger, slower prompt)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/run-rapid-qwen.sh" --bg
LEAN=(--no-skills --no-extensions --tools read,bash,edit,write)
[[ "${PI_FULL:-}" == 1 ]] && LEAN=(--tools read,bash,edit,write)
exec pi --provider qwen38-rapid-mlx --model qwen3.8-27b "${LEAN[@]}" "$@"
