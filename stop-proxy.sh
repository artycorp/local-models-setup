#!/bin/bash
PID_FILE="/tmp/llm-proxy.pid"
if [ -f "$PID_FILE" ]; then
  kill "$(cat $PID_FILE)" 2>/dev/null && echo "LLM proxy stopped" || echo "Already stopped"
  rm -f "$PID_FILE"
else
  kill "$(lsof -ti :8081)" 2>/dev/null && echo "LLM proxy stopped" || echo "Not running"
fi
