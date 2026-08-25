import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS || '8'),
      duration: '3m',
    },
  },
};

const base = __ENV.TARGET || 'http://localhost:8000';
const url = `${base}/v1/chat/completions`;
const payload = JSON.stringify({
  model: 'Qwen/Qwen2.5-7B-Instruct-AWQ',
  messages: [{ role: 'user', content: 'Explain spot instances in two sentences.' }],
  max_tokens: 128,
});

export default function () {
  const res = http.post(url, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '120s',
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
