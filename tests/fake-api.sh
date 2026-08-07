#!/usr/bin/env bash
#
# End-to-end test against a local stand-in for both the GitHub API and the
# container registry. Runs in dry-run, so no DELETE is ever issued — what this
# proves is the part most likely to be wrong: pagination, JSON parsing,
# newest-first ordering, and which versions land on the chopping block.
#
# The fixture is a multi-platform package on purpose. That is the case where
# "keep the newest N versions" and "keep the newest N deploys" disagree, and
# where getting it wrong deletes a child manifest and leaves a kept image
# unpullable.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../prune.sh"
port="${FAKE_API_PORT:-8791}"
# Nothing listens here. Used to prove the fail-closed path.
dead_port=$((port + 1))
pass=0
fail=0

py="$(command -v python3 || command -v python)" ||
  {
    echo "This test needs python3 to serve the fixtures."
    exit 1
  }

root="$(mktemp -d)"
mkdir -p "$root/users/testowner/packages/container/thing" \
  "$root/users/testowner/packages/container/simple" \
  "$root/users/testowner/packages/container/untagged" \
  "$root/v2/testowner/thing/manifests"

# Three deploys of a two-platform image, each one index manifest plus two
# per-platform children, and the newest also carrying a buildx attestation.
# Plus one orphan: an untagged manifest no live index references, left behind
# by a tag that was overwritten. created_at is deliberately scrambled — if the
# script trusted API order instead of sorting, the wrong versions would go.
cat >"$root/users/testowner/packages/container/thing/versions" <<'JSON'
[
  {"id": 202, "name": "sha256:b1",     "created_at": "2026-04-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 301, "name": "sha256:d3",     "created_at": "2026-05-01T00:00:00Z", "metadata": {"container": {"tags": ["latest", "sha-ccc"]}}},
  {"id": 101, "name": "sha256:d1",     "created_at": "2026-02-01T00:00:00Z", "metadata": {"container": {"tags": ["sha-aaa"]}}},
  {"id": 303, "name": "sha256:a2",     "created_at": "2026-05-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 999, "name": "sha256:orphan", "created_at": "2026-03-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 201, "name": "sha256:d2",     "created_at": "2026-04-01T00:00:00Z", "metadata": {"container": {"tags": ["sha-bbb"]}}},
  {"id": 304, "name": "sha256:att3",   "created_at": "2026-05-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 102, "name": "sha256:c1",     "created_at": "2026-02-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 203, "name": "sha256:b2",     "created_at": "2026-04-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 302, "name": "sha256:a1",     "created_at": "2026-05-01T00:00:00Z", "metadata": {"container": {"tags": []}}}
]
JSON

# A single-platform package: every version is tagged, so version == deploy and
# the registry is never consulted. This is the common case and it must keep
# working even when the registry is unreachable.
cat >"$root/users/testowner/packages/container/simple/versions" <<'JSON'
[
  {"id": 11, "name": "sha256:s1", "created_at": "2026-01-01T00:00:00Z", "metadata": {"container": {"tags": ["v1"]}}},
  {"id": 13, "name": "sha256:s3", "created_at": "2026-03-01T00:00:00Z", "metadata": {"container": {"tags": ["v3"]}}},
  {"id": 12, "name": "sha256:s2", "created_at": "2026-02-01T00:00:00Z", "metadata": {"container": {"tags": ["v2"]}}},
  {"id": 14, "name": "sha256:s4", "created_at": "2026-04-01T00:00:00Z", "metadata": {"container": {"tags": ["v4"]}}}
]
JSON

# Nothing tagged at all: no deploys to count, so nothing may be deleted.
cat >"$root/users/testowner/packages/container/untagged/versions" <<'JSON'
[
  {"id": 21, "name": "sha256:u1", "created_at": "2026-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
  {"id": 22, "name": "sha256:u2", "created_at": "2026-02-01T00:00:00Z", "metadata": {"container": {"tags": []}}}
]
JSON

# Index manifests, and the leaf manifests they point at. Digests are stored
# with the colon replaced by an underscore; see the server's translate_path.
man="$root/v2/testowner/thing/manifests"

write_index() {
  local name="$1"
  shift
  {
    printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":['
    local sep=""
    for child in "$@"; do
      printf '%s{"digest":"%s"}' "$sep" "$child"
      sep=","
    done
    printf ']}'
  } >"$man/${name//:/_}"
}

write_leaf() {
  printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}' \
    >"$man/${1//:/_}"
}

write_index sha256:d3 sha256:a1 sha256:a2 sha256:att3
write_index sha256:d2 sha256:b1 sha256:b2
write_index sha256:d1 sha256:c1
for leaf in sha256:a1 sha256:a2 sha256:att3 sha256:b1 sha256:b2 sha256:c1; do
  write_leaf "$leaf"
done

server="$(mktemp)"
cat >"$server" <<'PY'
import http.server, os, sys

root = sys.argv[1]


class Handler(http.server.SimpleHTTPRequestHandler):
    # A digest contains a colon, which is legal in a URL and in a POSIX
    # filename but not on every filesystem a checkout might live on, so the
    # fixtures store it as an underscore.
    def translate_path(self, path):
        path = path.split('?', 1)[0].split('#', 1)[0]
        return os.path.join(root, path.lstrip('/').replace(':', '_'))

    def log_message(self, *args):
        pass


http.server.HTTPServer(('127.0.0.1', int(sys.argv[2])), Handler).serve_forever()
PY

"$py" "$server" "$root" "$port" >/dev/null 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null
  rm -rf "$root" "$server"
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

saw() {
  printf '%s' "$log" | grep -q "$1" && echo yes || echo no
}

# Note the negated form rather than `grep -v`: -v succeeds whenever *any* line
# lacks the text, which would make the assertion unfalsifiable.
did_not_see() {
  printf '%s' "$log" | grep -q "$1" && echo no || echo yes
}

run_prune() {
  local keep="$1" pkg="${2:-thing}" reg="${3:-http://127.0.0.1:$port}"
  out_file="$(mktemp)"
  log="$(GITHUB_API_URL="http://127.0.0.1:$port" \
    GHCR_PRUNE_REGISTRY="$reg" \
    INPUT_TOKEN=fake \
    INPUT_OWNER=testowner \
    INPUT_PACKAGE="$pkg" \
    INPUT_KEEP_LAST="$keep" \
    INPUT_DRY_RUN=true \
    GITHUB_OUTPUT="$out_file" \
    bash "$script" 2>&1)"
  rc=$?
}

# ------------------------------------- keep 2 deploys of 3 (10 versions)

run_prune 2

check 'exits successfully' "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'counts versions and deploys separately' \
  "$(saw 'Found 10 version(s) across 3 deploy(s); 3 over the limit')"

check 'deletes the oldest deploy index' "$(saw 'would delete 101')"
check "deletes that deploy's child manifest" "$(saw 'would delete 102')"
check 'deletes the orphaned untagged manifest' "$(saw 'would delete 999')"

for id in 201 202 203 301 302 303 304; do
  check "keeps $id" "$(did_not_see "would delete $id")"
done

check 'deleted-count is 0 on a dry run' \
  "$(grep -qx 'deleted-count=0' "$out_file" && echo yes || echo no)"
check 'kept-count is 7 — two whole deploys' \
  "$(grep -qx 'kept-count=7' "$out_file" && echo yes || echo no)"
check 'deleted-ids lists the three doomed versions, newest first' \
  "$(grep -qx 'deleted-ids=999 102 101' "$out_file" && echo yes || echo no)"

# --------------------- keep more deploys than exist: orphans still go

run_prune 10

check 'keeping more deploys than exist exits successfully' \
  "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'every deploy is retained' "$(saw 'across 3 deploy(s); 1 over the limit')"
check 'the orphan is still collected' "$(saw 'would delete 999')"
check 'no tagged version is touched' "$(did_not_see 'would delete 101')"

# ------------------------- registry unreachable: fail closed, keep untagged

run_prune 2 thing "http://127.0.0.1:$dead_port"

check 'an unreachable registry does not fail the step' \
  "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'an unreachable registry is warned about' \
  "$(saw "::warning::Could not read manifests")"
check 'the older deploy is still pruned' "$(saw 'would delete 101')"
for id in 102 999 202 203 302 303 304; do
  check "untagged $id is kept when manifests are unreadable" \
    "$(did_not_see "would delete $id")"
done

# ---------------- single-platform package never consults the registry

run_prune 3 simple "http://127.0.0.1:$dead_port"

check 'an all-tagged package exits successfully with no registry' \
  "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'an all-tagged package does not warn about the registry' \
  "$(did_not_see '::warning::')"
check 'an all-tagged package treats each version as a deploy' \
  "$(saw 'Found 4 version(s) across 4 deploy(s); 1 over the limit')"
check 'the oldest tagged version goes' "$(saw 'would delete 11')"

# ------------------------------- no tags at all: refuse to delete anything

run_prune 1 untagged

check 'a package with no tags exits successfully' \
  "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check 'a package with no tags is refused' \
  "$(saw 'no deploys to count')"
check 'a package with no tags loses nothing' "$(did_not_see 'would delete')"
check 'a package with no tags reports everything kept' \
  "$(grep -qx 'kept-count=2' "$out_file" && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
