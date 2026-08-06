#!/usr/bin/env bash
#
# End-to-end test against a local static server standing in for the GitHub
# API. Runs in dry-run, so no DELETE is ever issued — what this proves is the
# part most likely to be wrong: pagination, JSON parsing, newest-first
# ordering, and which versions land on the chopping block.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../prune.sh"
port="${FAKE_API_PORT:-8791}"
pass=0
fail=0

py="$(command -v python3 || command -v python)" ||
  {
    echo "This test needs python3 to serve the fixtures."
    exit 1
  }

root="$(mktemp -d)"
pkg_dir="$root/users/testowner/packages/container/thing"
mkdir -p "$pkg_dir"

# created_at deliberately out of order: if the script trusted API order
# instead of sorting, the wrong versions would be selected.
cat >"$pkg_dir/versions" <<'JSON'
[
  {"id": 101, "created_at": "2026-01-01T00:00:00Z", "metadata": {"container": {"tags": ["oldest"]}}},
  {"id": 102, "created_at": "2026-03-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 103, "created_at": "2026-02-01T00:00:00Z", "metadata": {"container": {"tags": ["sha-abc"]}}},
  {"id": 104, "created_at": "2026-05-01T00:00:00Z", "metadata": {"container": {"tags": ["latest"]}}},
  {"id": 105, "created_at": "2026-04-01T00:00:00Z", "metadata": {"container": {"tags": ["sha-def"]}}}
]
JSON

"$py" -m http.server "$port" --bind 127.0.0.1 --directory "$root" >/dev/null 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null
  rm -rf "$root"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  curl -fsS -o /dev/null "http://127.0.0.1:$port/users/testowner/packages/container/thing/versions" 2>/dev/null && break
  sleep 0.2
done || true

check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "yes" ]; then
    printf 'ok    %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$desc"
    fail=$((fail + 1))
  fi
}

run_prune() {
  local keep="$1"
  out_file="$(mktemp)"
  log="$(GITHUB_API_URL="http://127.0.0.1:$port" \
    INPUT_TOKEN=fake \
    INPUT_OWNER=testowner \
    INPUT_PACKAGE=thing \
    INPUT_KEEP_LAST="$keep" \
    INPUT_DRY_RUN=true \
    GITHUB_OUTPUT="$out_file" \
    bash "$script" 2>&1)"
  rc=$?
}

# ---------------------------------------------------- keep 2 of 5 versions

run_prune 2

check 'exits successfully' "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'finds all five versions' \
  "$(printf '%s' "$log" | grep -q 'Found 5 version(s); 3 over the limit' && echo yes || echo no)"

for id in 101 102 103; do
  check "would delete $id" \
    "$(printf '%s' "$log" | grep -q "would delete $id" && echo yes || echo no)"
done
for id in 104 105; do
  # Note the negated grep, not `grep -v`: -v succeeds whenever *any* line
  # lacks the text, which would make this assertion unfalsifiable.
  check "keeps $id (newest two)" \
    "$(printf '%s' "$log" | grep -q "would delete $id" && echo no || echo yes)"
done

check 'deleted-count is 0 on a dry run' \
  "$(grep -qx 'deleted-count=0' "$out_file" && echo yes || echo no)"
check 'kept-count is 2' \
  "$(grep -qx 'kept-count=2' "$out_file" && echo yes || echo no)"
check 'deleted-ids lists the three oldest, newest first' \
  "$(grep -qx 'deleted-ids=102 103 101' "$out_file" && echo yes || echo no)"

# ------------------------------------------- keep more than exist: no-op

run_prune 10

check 'keeping more than exist exits successfully' "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'keeping more than exist prunes nothing' \
  "$(printf '%s' "$log" | grep -q 'Nothing to prune' && echo yes || echo no)"
check 'keeping more than exist retains all five' \
  "$(grep -qx 'kept-count=5' "$out_file" && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
