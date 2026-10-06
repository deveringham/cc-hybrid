#!/usr/bin/env bash
# Smoke-test llama-server locally. Run ON THE QUADRO NODE after starting the service.
# Verifies: health, basic completion, and (critically) tool calling.
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8080}"
pass=0; fail=0
ok()   { printf '\033[1;32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "Testing $BASE"
echo

# 1. health -------------------------------------------------------------------
if curl -sf --max-time 10 "$BASE/health" >/dev/null; then
  ok "health endpoint responding"
else
  bad "health endpoint unreachable — is the service running? (systemctl --user status llama-server)"
  exit 1
fi

# 2. model is loaded ----------------------------------------------------------
models=$(curl -sf --max-time 10 "$BASE/v1/models" || echo '')
if echo "$models" | grep -q '"id"'; then
  ok "model loaded: $(echo "$models" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
else
  bad "/v1/models returned nothing useful"
fi

# 3. plain completion ---------------------------------------------------------
resp=$(curl -sf --max-time 120 "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with exactly the word: ready"}],"max_tokens":16,"temperature":0}' || echo '')
if echo "$resp" | grep -qi 'ready'; then
  ok "basic completion works"
else
  bad "basic completion failed. Response: ${resp:0:300}"
fi

# 4. TOOL CALLING — the one that actually matters for Claude Code -------------
tool_resp=$(curl -sf --max-time 120 "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "messages":[{"role":"user","content":"Read the file /etc/hostname using the available tool."}],
    "tools":[{
      "type":"function",
      "function":{
        "name":"read_file",
        "description":"Read the contents of a file from disk",
        "parameters":{
          "type":"object",
          "properties":{"path":{"type":"string","description":"Absolute path to the file"}},
          "required":["path"]
        }
      }
    }],
    "tool_choice":"auto",
    "max_tokens":256,
    "temperature":0
  }' || echo '')

if echo "$tool_resp" | grep -q '"tool_calls"'; then
  ok "tool calling works (model emitted a structured tool_calls block)"
elif echo "$tool_resp" | grep -q 'read_file'; then
  bad "model mentioned the tool but did NOT emit structured tool_calls."
  echo "     => llama-server is probably missing --jinja, or the chat template is wrong."
  echo "     => Try adding --chat-template-file with the model's own .jinja template."
else
  bad "no tool call at all. Response: ${tool_resp:0:400}"
fi

# 5. context size -------------------------------------------------------------
props=$(curl -sf --max-time 10 "$BASE/props" || echo '')
n_ctx=$(echo "$props" | grep -o '"n_ctx":[0-9]*' | head -1 | cut -d: -f2)
if [ -n "$n_ctx" ] && [ "$n_ctx" -ge 32768 ] 2>/dev/null; then
  ok "context size is $n_ctx (>= 32768, adequate for Claude Code)"
elif [ -n "$n_ctx" ]; then
  bad "context size is only $n_ctx — Claude Code will hit HTTP 400. Raise CTX_SIZE."
else
  echo "     (could not read /props; skipping context check)"
fi

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ] || exit 1
