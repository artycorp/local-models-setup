#!/bin/bash
# Запускает llm-proxy если не запущен
PROXY_PORT=8081
PID_FILE="/tmp/llm-proxy.pid"

if lsof -ti :$PROXY_PORT >/dev/null 2>&1; then
  echo "LLM proxy already running on :$PROXY_PORT"
  exit 0
fi

node "$(dirname "$0")/llm-proxy.mjs" &
echo $! > "$PID_FILE"
sleep 0.3
echo "LLM proxy started (pid=$(cat $PID_FILE))"
echo "Stats: ~/.llm-stats"
