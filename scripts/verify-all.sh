#!/usr/bin/env bash
# End-to-end verification of the whole stack. Prints a PASS/FAIL/SKIP matrix and
# exits non-zero if anything that should work does not.
#
#   bash scripts/verify-all.sh          # connections only
#   LIVE=1 bash scripts/verify-all.sh   # + one real tool call per MCP server and
#                                       #   a 16-token completion on the model
#
# Nothing here needs sudo, and every network call is to a service you own or
# the local machine.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DSH_HOME="${DSH_HOME:-$ROOT/.dsh-home}"
PROFILE="${DSH_PROFILE:-web}"
LIVE="${LIVE:-0}"
MODEL="abliterated-model-large-flash"
API="https://api.abliteration.ai/v1"

results=()
record() { results+=("$1|$2|$3"); } # status | name | detail
pass() { record PASS "$1" "$2"; printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "$2"; }
fail() { record FAIL "$1" "$2"; printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "$2"; }
skip() { record SKIP "$1" "$2"; printf '  \033[33mSKIP\033[0m  %-34s %s\n' "$1" "$2"; }

if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

echo
echo "== 1. toolchain =="
if command -v node >/dev/null && [[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]]; then
  pass "node" "$(node -v)"
else
  fail "node" "need Node.js >= 22"
fi

if [[ -x node_modules/.bin/dsh ]]; then
  pass "deepseek harness" "$(node_modules/.bin/dsh --version 2>/dev/null | head -1)"
else
  fail "deepseek harness" "not installed -- run: npm install"
fi

echo
echo "== 2. secrets =="
if [[ "${ABLIT_KEY:-}" == ak_* && "${ABLIT_KEY:-}" != "ak_REPLACE_ME" ]]; then
  pass "ABLIT_KEY" "set (…${ABLIT_KEY: -4})"
else
  fail "ABLIT_KEY" "missing or placeholder in .env"
fi
if [[ "${FIRECRAWL_API_KEY:-}" == fc-* && "${FIRECRAWL_API_KEY:-}" != "fc_REPLACE_ME" ]]; then
  pass "FIRECRAWL_API_KEY" "set (…${FIRECRAWL_API_KEY: -4})"
else
  skip "FIRECRAWL_API_KEY" "not set -- firecrawl tools will fail at call time"
fi

echo
echo "== 3. harness config composes =="
if dump="$(DSH_HOME="$DSH_HOME" node_modules/.bin/dsh "$PROFILE" --dump-config 2>/dev/null)"; then
  grep -q "$MODEL" <<<"$dump" \
    && pass "provider route" "abliteration -> $MODEL" \
    || fail "provider route" "$MODEL missing from --dump-config"
  for id in mcp-playwright mcp-firecrawl; do
    grep -q "$id" <<<"$dump" \
      && pass "mcp row: $id" "present in composed config" \
      || fail "mcp row: $id" "missing from composed config"
  done
  grep -q 'cordis.patch.yml' <<<"$dump" \
    && pass "patch layer" "dsh/cordis.patch.yml is applied" \
    || skip "patch layer" "no patch marker in composed config"
else
  fail "harness config" "--dump-config failed"
fi

echo
echo "== 4. abliteration API =="
if [[ "${ABLIT_KEY:-}" == ak_* && "${ABLIT_KEY:-}" != "ak_REPLACE_ME" ]]; then
  code="$(curl -sS -o /tmp/ablit-models.json -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $ABLIT_KEY" "$API/models" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    if node -e 'const d=require("/tmp/ablit-models.json");const ids=(d.data??[]).map(m=>m.id);process.exit(ids.includes(process.argv[1])?0:1)' "$MODEL"; then
      pass "GET /v1/models" "200, $MODEL listed"
    else
      fail "GET /v1/models" "200 but $MODEL not in $(node -p 'JSON.parse(require("fs").readFileSync("/tmp/ablit-models.json")).data.map(m=>m.id).join(",")' 2>/dev/null)"
    fi
  else
    fail "GET /v1/models" "HTTP $code (check key / network)"
  fi

  if [[ "$LIVE" == "1" ]]; then
    body="$(curl -sS --max-time 90 "$API/chat/completions" \
      -H "Authorization: Bearer $ABLIT_KEY" -H 'content-type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ok\"}],\"max_tokens\":16,\"reasoning_effort\":\"none\"}" 2>/dev/null)"
    if node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const t=d.choices?.[0]?.message?.content;if(!t)process.exit(1);console.log(JSON.stringify({text:t.trim().slice(0,40),usage:d.usage}))' <<<"$body"; then
      pass "chat completion" "$MODEL answered (see usage above)"
    else
      fail "chat completion" "$(head -c 200 <<<"$body")"
    fi
  else
    skip "chat completion" "set LIVE=1 to send a 16-token request"
  fi
else
  skip "abliteration API" "no valid ABLIT_KEY"
fi

echo
echo "== 5. MCP servers (real handshake + tools/list) =="
mcp_args=()
[[ "$LIVE" == "1" ]] && mcp_args+=(--live)
if [[ -n "${FIRECRAWL_API_KEY:-}" && "${FIRECRAWL_API_KEY:-}" == fc-* && "${FIRECRAWL_API_KEY:-}" != "fc_REPLACE_ME" ]]; then
  if node mcp/verify-mcp.mjs "${mcp_args[@]}" 2>&1 | sed 's/^/  /'; then
    if [[ "$LIVE" == "1" ]]; then
      pass "playwright + firecrawl" "handshake, tools listed, live call OK"
    else
      pass "playwright + firecrawl" "handshake, tools listed"
    fi
  else
    fail "playwright + firecrawl" "see output above"
  fi
else
  if node mcp/verify-mcp.mjs --only playwright "${mcp_args[@]}" 2>&1 | sed 's/^/  /'; then
    pass "playwright" "handshake, tools listed"
  else
    fail "playwright" "see output above"
  fi
  skip "firecrawl" "handshake not run without FIRECRAWL_API_KEY"
fi

echo
echo "== 6. browsers =="
if ls "$HOME"/.cache/ms-playwright/chromium* >/dev/null 2>&1; then
  pass "playwright chromium" "installed"
else
  fail "playwright chromium" "missing -- run: npx playwright install chromium"
fi

echo
echo "== 7. nuclei =="
if [[ -x bin/nuclei ]]; then
  pass "nuclei binary" "$(bin/nuclei -version 2>&1 | head -1)"
  if [[ -d "${HOME}/.local/nuclei-templates" ]]; then
    pass "nuclei templates" "$(find "${HOME}/.local/nuclei-templates" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ') templates cached"
  else
    skip "nuclei templates" "downloaded on first scan"
  fi
else
  skip "nuclei binary" "run: bash security/nuclei/install-nuclei.sh"
fi

echo
echo "== 8. local test app =="
if curl -fsS --max-time 3 "http://127.0.0.1:${TESTAPP_PORT:-8787}/health" >/dev/null 2>&1; then
  pass "test app" "healthy on http://127.0.0.1:${TESTAPP_PORT:-8787}"
  if bash security/nuclei/scan.sh --self-test >/dev/null 2>&1; then
    pass "loopback scan guard" "accepts loopback, rejects public targets"
  else
    fail "loopback scan guard" "run: bash security/nuclei/scan.sh --self-test"
  fi
else
  skip "test app" "not running -- start with: npm run testapp"
fi

echo
echo "== summary =="
printf '  %-40s %s\n' "PASS" "$(printf '%s\n' "${results[@]}" | grep -c '^PASS|' || true)"
printf '  %-40s %s\n' "SKIP" "$(printf '%s\n' "${results[@]}" | grep -c '^SKIP|' || true)"
printf '  %-40s %s\n' "FAIL" "$(printf '%s\n' "${results[@]}" | grep -c '^FAIL|' || true)"
echo
if printf '%s\n' "${results[@]}" | grep -q '^FAIL|'; then
  echo "verification FAILED:"
  printf '%s\n' "${results[@]}" | awk -F'|' '$1=="FAIL"{printf "  - %s: %s\n", $2, $3}'
  exit 1
fi
echo "all checks passed"
