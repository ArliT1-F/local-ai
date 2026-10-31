#!/usr/bin/env bash
# Run nuclei against the LOCAL test app only.
#
# Safety model: this script refuses any target that is not a loopback address.
# The guard is not a flag you can turn off -- if you want to scan something
# else, you are on your own time and your own authorization.
#
#   bash security/nuclei/scan.sh                       # http://127.0.0.1:8787
#   bash security/nuclei/scan.sh http://127.0.0.1:3000
#   bash security/nuclei/scan.sh --list-tags
#
# Docs: https://github.com/projectdiscovery/nuclei
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NUCLEI="$ROOT/bin/nuclei"
FINDINGS="$ROOT/security/findings"
TARGET="${1:-${TESTAPP_URL:-http://127.0.0.1:${TESTAPP_PORT:-8787}}}"

# Destructive / noisy template families are excluded even on the test app, so a
# scan can never saturate the box or fuzz the app into an unrelated state.
EXCLUDE_TAGS="${NUCLEI_EXCLUDE_TAGS:-dos,fuzz,intrusive,brute-force,file,headless}"

die() { echo "error: $*" >&2; exit 1; }

# --- loopback guard ------------------------------------------------------
assert_loopback() {
  local url="$1"
  [[ "$url" =~ ^https?://[^/]+ ]] || die "target must be an http(s) URL, got: $url"
  local authority="${url#*://}"
  authority="${authority%%/*}"
  local hostport="${authority##*@}"          # strip any userinfo
  local host
  if [[ "$hostport" =~ ^\[([^]]*)\] ]]; then
    host="${BASH_REMATCH[1]}"                 # [::1]:8787 -> ::1
  else
    host="${hostport%%:*}"
  fi
  case "$host" in
    127.0.0.1 | localhost | ::1 | 0:0:0:0:0:0:0:1) return 0 ;;
    *) die "refusing to scan '$host': only loopback targets are allowed (127.0.0.1 / localhost / ::1)" ;;
  esac
}

# --- self-test -----------------------------------------------------------
# `--self-test` exercises the guard without touching the network; used by
# scripts/verify-all.sh.
if [[ "${1:-}" == "--self-test" ]]; then
  assert_loopback "http://127.0.0.1:8787" || exit 1
  assert_loopback "https://localhost:8443/x?y=1" || exit 1
  assert_loopback "http://[::1]:8787" || exit 1
  for bad in "http://example.com" "http://10.0.0.5:8080" "http://192.168.1.1" "http://127.0.0.1.evil.com" "ftp://127.0.0.1"; do
    if (assert_loopback "$bad") 2>/dev/null; then
      echo "self-test FAILED: guard accepted $bad" >&2
      exit 1
    fi
  done
  echo "self-test ok: loopback allowed, non-loopback refused"
  exit 0
fi

if [[ "${1:-}" == "--list-tags" ]]; then
  [[ -x "$NUCLEI" ]] || die "nuclei not installed, run: bash security/nuclei/install-nuclei.sh"
  exec "$NUCLEI" -tl
fi

assert_loopback "$TARGET"

if [[ ! -x "$NUCLEI" ]]; then
  echo "nuclei not found at bin/nuclei -- installing it now."
  bash "$ROOT/security/nuclei/install-nuclei.sh"
fi

# The app must actually be running; otherwise nuclei reports a boring
# "no results" and you learn nothing.
if ! curl -fsS --max-time 5 "${TARGET%/}/health" >/dev/null 2>&1; then
  die "nothing healthy at ${TARGET%/}/health -- start the test app first: npm run testapp"
fi

mkdir -p "$FINDINGS"
stamp="$(date +%Y%m%d-%H%M%S)"
jsonl="$FINDINGS/nuclei-$stamp.jsonl"
log="$FINDINGS/nuclei-$stamp.log"

echo "Target   : $TARGET"
echo "Template : nuclei-templates ($( [[ -d "${HOME}/.local/nuclei-templates" ]] && echo cached || echo 'first run downloads them' ))"
echo "Excluded : $EXCLUDE_TAGS"
echo "Output   : $jsonl"
echo

set +e
"$NUCLEI" \
  -u "$TARGET" \
  -severity low,medium,high,critical \
  -exclude-tags "$EXCLUDE_TAGS" \
  -rate-limit 40 \
  -concurrency 20 \
  -timeout 10 \
  -retries 1 \
  -stats \
  -nc \
  -jsonl \
  -output "$jsonl" \
  2>&1 | tee "$log"
status=$?
set -e

# nuclei exits non-zero when it finds nothing in some versions; judge by output.
if [[ -f "$jsonl" ]]; then
  findings=$(grep -c . "$jsonl" || true)
else
  findings=0
fi

echo
echo "Findings: $findings"
if [[ "$findings" -gt 0 ]] && command -v node >/dev/null; then
  node -e '
    const fs = require("node:fs");
    const rows = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
    const bySeverity = {};
    for (const r of rows) {
      const s = (r.info?.severity ?? "unknown").toLowerCase();
      bySeverity[s] = (bySeverity[s] ?? 0) + 1;
    }
    for (const [sev, n] of Object.entries(bySeverity).sort()) console.log(`  ${sev.padEnd(9)} ${n}`);
    console.log("\nTop hits:");
    for (const r of rows.slice(0, 15)) {
      console.log(`  [${(r.info?.severity ?? "?").toUpperCase()}] ${r["template-id"]} ${r["matched-at"] ?? ""}`);
    }
  ' "$jsonl"
fi

exit $status
