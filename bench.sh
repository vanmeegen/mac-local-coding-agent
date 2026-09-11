#!/usr/bin/env bash
#
# bench.sh — quick, dependency-free tok/s check against the local server.
#
#   ./bench.sh                              # driver model on oMLX
#   ./bench.sh Qwen3.8-27B-oQ6e-mtp         # another model
#   BASE_URL=http://localhost:11434/v1 ./bench.sh qwen3.8-coder   # Ollama fallback
#
# Measures three things that matter for an agent loop:
#   1. cold prefill  — a ~8k-token prompt, max_tokens=1 → prompt tok/s
#   2. cached prefill — the SAME prompt again → shows the prefix cache (oMLX)
#   3. generation    — 256 tokens on a short prompt → decode tok/s (MTP on)
#
set -euo pipefail
export LC_ALL=C   # printf %.1f must accept a dot regardless of the user's locale
MODEL="${1:-Qwen3.8-27B-oQ4e-mtp}"
BASE_URL="${BASE_URL:-http://localhost:8000/v1}"
API_KEY="${API_KEY:-local}"

req() { # $1 = json body → prints "<elapsed_s> <prompt_tokens> <completion_tokens>"
  local body="$1" start end resp
  start=$(python3 -c 'import time;print(time.time())')
  resp=$(curl -sS -m 900 "$BASE_URL/chat/completions" \
    -H "content-type: application/json" -H "authorization: Bearer $API_KEY" -d "$body")
  end=$(python3 -c 'import time;print(time.time())')
  python3 - "$start" "$end" "$resp" <<'PY'
import sys, json
start, end, raw = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(f"non-JSON reply: {raw[:300]}")
if "error" in d:
    sys.exit(f"server error: {json.dumps(d['error'])[:300]}")
u = d.get("usage") or {}
print(f"{end-start:.3f} {u.get('prompt_tokens', 0)} {u.get('completion_tokens', 0)}")
PY
}

# ~8k tokens of deterministic filler (code-ish so the tokenizer behaves like a repo).
# A per-run nonce on the first line guarantees run 1 is a genuine cache miss
# (oMLX matches prefixes, so a repeated filler alone would already hit).
LONG=$(python3 -c '
import secrets
lines = [f"// bench run {secrets.token_hex(8)}"]
lines += [f"export function fn{i}(a: number, b: number): number {{ return a * {i} + b; }} // line {i}" for i in range(250)]
print("\n".join(lines))')
LONG_JSON=$(python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' <<<"$LONG")

echo "model:    $MODEL"
echo "endpoint: $BASE_URL"
echo

echo "1) cold prefill (max_tokens=1)…"
read -r t1 p1 _ < <(req "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":$LONG_JSON}],\"max_tokens\":1,\"temperature\":0}")
printf '   %s prompt tokens in %ss → %.0f tok/s prefill\n' "$p1" "$t1" "$(python3 -c "print($p1/$t1)")"

echo "2) cached prefill (same prompt again)…"
read -r t2 p2 _ < <(req "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":$LONG_JSON}],\"max_tokens\":1,\"temperature\":0}")
printf '   %s prompt tokens in %ss → %.1fx faster than cold\n' "$p2" "$t2" "$(python3 -c "print($t1/max($t2,0.001))")"

echo "3) generation (256 tokens)…"
read -r t3 _ c3 < <(req "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a TypeScript function that parses a CSV string into an array of objects, with a short usage example. No explanation.\"}],\"max_tokens\":256,\"temperature\":1.0,\"top_p\":0.95}")
printf '   %s completion tokens in %ss → %.1f tok/s decode (includes TTFT)\n' "$c3" "$t3" "$(python3 -c "print($c3/$t3)")"
