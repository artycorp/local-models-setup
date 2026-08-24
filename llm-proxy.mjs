#!/usr/bin/env node
// LLM Stats Proxy — перехватывает llamacpp ответы, пишет статистику в ~/.llm-stats
// Запуск: node llm-proxy.mjs
// Потом:  cat ~/.llm-stats

import http from 'http';
import fs from 'fs';
import path from 'path';
import os from 'os';

const TARGET_HOST = '192.168.10.25';   // box .25 — winning Gemma-26B-A4B server
const TARGET_PORT = 8081;
const PROXY_PORT  = 8081;
const STATS_FILE  = path.join(os.homedir(), '.llm-stats');
const CTX_SIZE    = 98304;             // 96K window

let reqCount = 0;

function contextBar(used, total, width = 24) {
  const ratio  = Math.min(used / total, 1);
  const filled = Math.round(ratio * width);
  return '█'.repeat(filled) + '░'.repeat(width - filled);
}

function writeStats(timings) {
  reqCount++;
  const inTok  = (timings.prompt_n || 0) + (timings.cache_n || 0);
  const outTok = timings.predicted_n || 0;
  const total  = inTok + outTok;
  const pct    = ((total / CTX_SIZE) * 100).toFixed(1);
  const speed  = (timings.predicted_per_second || 0).toFixed(1);
  const prefill = (timings.prompt_per_second || 0).toFixed(0);
  const ts     = new Date().toLocaleTimeString('ru-RU', { hour12: false });

  const content = [
    `Updated: ${ts}  •  request #${reqCount}`,
    ``,
    `Context  [${contextBar(total, CTX_SIZE)}]  ${pct}%`,
    `         ${total.toLocaleString()} / ${CTX_SIZE.toLocaleString()} tokens`,
    ``,
    `Input    ${inTok.toLocaleString()} tok  (${(timings.cache_n || 0).toLocaleString()} cached, ${(timings.prompt_n || 0).toLocaleString()} new)`,
    `Output   ${outTok.toLocaleString()} tok`,
    ``,
    `Speed    ${speed} tok/s  (prefill: ${prefill} tok/s)`,
  ].join('\n');

  fs.writeFileSync(STATS_FILE, content + '\n');
}

// Ищем timings в SSE-потоке или в JSON-ответе
function extractTimings(rawBody) {
  // Streaming SSE: ищем с конца — timings в последнем data-чанке (с finish_reason)
  if (rawBody.includes('"timings"')) {
    const lines = rawBody.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (line.startsWith('data: ') && line !== 'data: [DONE]') {
        try {
          const obj = JSON.parse(line.slice(6));
          if (obj.timings) return obj.timings;
        } catch {}
      }
    }
    // Non-streaming JSON
    try {
      const obj = JSON.parse(rawBody);
      if (obj.timings) return obj.timings;
    } catch {}
  }
  return null;
}

const server = http.createServer((req, res) => {
  const isCompletion = /\/completions/.test(req.url);

  const proxyReq = http.request(
    {
      host: TARGET_HOST,
      port: TARGET_PORT,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, host: `${TARGET_HOST}:${TARGET_PORT}` },
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);

      if (isCompletion) {
        const chunks = [];
        proxyRes.on('data', (chunk) => {
          res.write(chunk);    // немедленно отправляем клиенту — задержки нет
          chunks.push(chunk);
        });
        proxyRes.on('end', () => {
          res.end();
          const body    = Buffer.concat(chunks).toString('utf8');
          const timings = extractTimings(body);
          if (timings) writeStats(timings);
        });
      } else {
        proxyRes.pipe(res);
      }
    }
  );

  proxyReq.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
    }
    res.end(JSON.stringify({ error: { message: err.message, type: 'proxy_error' } }));
  });

  req.pipe(proxyReq);
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  fs.writeFileSync(STATS_FILE, 'Waiting for first request...\n');
  console.log(`LLM proxy: localhost:${PROXY_PORT} → ${TARGET_HOST}:${TARGET_PORT}`);
  console.log(`Stats:     ${STATS_FILE}`);
});
