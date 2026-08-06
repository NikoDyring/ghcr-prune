#!/usr/bin/env bash
#
# Delete old GitHub Packages versions, keeping the newest N.
#
# Deliberately plain shell + curl: a composite action has no `using: nodeXX`
# runtime, so it can never be deprecated out from under its users the way
# JavaScript actions are. The only cost is needing a JSON parser on the
# runner, which is why jq and python3 are both accepted below.

set -euo pipefail

api="${GITHUB_API_URL:-https://api.github.com}"
owner="${INPUT_OWNER:-}"
package="${INPUT_PACKAGE:-}"
package_type="${INPUT_PACKAGE_TYPE:-container}"
keep="${INPUT_KEEP_LAST:-3}"
dry_run="${INPUT_DRY_RUN:-false}"
token="${INPUT_TOKEN:-}"

# Lets the script run outside Actions (tests, manual debugging) without
# tripping `set -u` on the first output write.
: "${GITHUB_OUTPUT:=/dev/null}"

fail() {
  echo "::error::$*"
  exit 1
}

# ---------------------------------------------------------------- validation

[ -n "$token" ] || fail "No token supplied. Pass \`token:\` or grant the job \`permissions: packages: write\`."

owner="${owner:-${GITHUB_REPOSITORY_OWNER:-}}"
[ -n "$owner" ] || fail "Could not determine the package owner. Pass \`owner:\`."

if [ -z "$package" ]; then
  [ -n "${GITHUB_REPOSITORY:-}" ] || fail "Could not determine the package name. Pass \`package:\`."
  package="${GITHUB_REPOSITORY##*/}"
fi

case "$package_type" in
container | npm | maven | rubygems | nuget) ;;
*) fail "Unsupported package-type '$package_type'. Use container, npm, maven, rubygems or nuget." ;;
esac

case "$keep" in
'' | *[!0-9]*) fail "keep-last must be a whole number, got '$keep'." ;;
esac
[ "$keep" -ge 1 ] || fail "keep-last must be 1 or more (refusing to delete every version)."

case "$dry_run" in
true | false) ;;
*) fail "dry-run must be true or false, got '$dry_run'." ;;
esac

# A scoped npm name like @scope/pkg has to be encoded for the path segment.
package_path="${package//\//%2F}"

# --------------------------------------------------------------- json parser

# GHCR_PRUNE_JSON forces a specific parser. Mostly here so CI can exercise
# both branches without filesystem surgery, but also an escape hatch if a
# runner's jq is broken.
json_tool="${GHCR_PRUNE_JSON:-}"
if [ -z "$json_tool" ]; then
  if command -v jq >/dev/null 2>&1; then
    json_tool=jq
  elif command -v python3 >/dev/null 2>&1; then
    json_tool=python3
  fi
fi

command -v "${json_tool:-nothing-available}" >/dev/null 2>&1 ||
  fail "Needs either jq or python3 on the runner; found neither${json_tool:+ (GHCR_PRUNE_JSON=$json_tool is not on PATH)}. Install one, or use a GitHub-hosted runner (both are preinstalled)."

if [ "$json_tool" = jq ]; then
  parse_versions() {
    jq -r '.[] | [.created_at, (.id | tostring), ((.metadata.container.tags // []) | join(","))] | @tsv'
  }
  parse_owner_type() { jq -r '.type // empty'; }
else
  parse_versions() {
    "$json_tool" -c '
import json, sys
for v in json.load(sys.stdin):
    tags = ((v.get("metadata") or {}).get("container") or {}).get("tags") or []
    print("{}\t{}\t{}".format(v["created_at"], v["id"], ",".join(tags)))
'
  }
  parse_owner_type() {
    "$json_tool" -c 'import json,sys; print(json.load(sys.stdin).get("type",""))'
  }
fi

request() {
  curl -sS --fail-with-body \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# ------------------------------------------------------------- resolve owner

# User- and org-owned packages live on different paths, and using the wrong
# one 404s. Ask which this is rather than making the caller tell us.
owner_type="$(request "$api/users/$owner" 2>/dev/null | parse_owner_type 2>/dev/null || true)"
if [ "$owner_type" = "Organization" ]; then
  scope="orgs"
else
  scope="users"
fi

base="$api/$scope/$owner/packages/$package_type/$package_path"
echo "Pruning $package_type package '$package' owned by $owner ($scope), keeping the newest $keep."

# --------------------------------------------------------------- list them all

versions=""
page=1
while :; do
  if ! body="$(request "$base/versions?per_page=100&page=$page")"; then
    fail "Could not list versions of '$package'. Check the package exists, the owner is right, and the token has \`packages: write\` on it. Response: $(echo "$body" | tr -d '\n' | cut -c1-300)"
  fi

  if ! rows="$(printf '%s' "$body" | parse_versions 2>/dev/null)"; then
    fail "Could not parse the API response as a list of versions (page $page). Response: $(printf '%s' "$body" | tr -d '\n' | cut -c1-300)"
  fi
  [ -n "$rows" ] || break

  versions+="$rows"$'\n'

  # A short page is the last page.
  [ "$(printf '%s\n' "$rows" | grep -c .)" -lt 100 ] && break
  page=$((page + 1))
done

versions="$(printf '%s' "$versions" | grep . || true)"
total="$(printf '%s\n' "$versions" | grep -c . || true)"

if [ "$total" -eq 0 ]; then
  echo "No versions found; nothing to do."
  {
    echo "deleted-count=0"
    echo "deleted-ids="
    echo "kept-count=0"
  } >>"$GITHUB_OUTPUT"
  exit 0
fi

# Newest first. ISO-8601 sorts correctly as text; id breaks ties so that
# versions pushed in the same second get a stable order.
sorted="$(printf '%s\n' "$versions" | sort -t"$(printf '\t')" -k1,1r -k2,2nr)"
doomed="$(printf '%s\n' "$sorted" | tail -n +$((keep + 1)))"
doomed_count="$(printf '%s\n' "$doomed" | grep -c . || true)"

echo "Found $total version(s); $doomed_count over the limit."

if [ "$doomed_count" -eq 0 ]; then
  echo "Nothing to prune."
  {
    echo "deleted-count=0"
    echo "deleted-ids="
    echo "kept-count=$total"
  } >>"$GITHUB_OUTPUT"
  exit 0
fi

# ------------------------------------------------------------------- prune

deleted_ids=()
failures=0

while IFS=$'\t' read -r created id tags; do
  [ -n "$id" ] || continue
  label="$id  $created${tags:+  [$tags]}"

  if [ "$dry_run" = "true" ]; then
    echo "  would delete $label"
    deleted_ids+=("$id")
    continue
  fi

  if request -X DELETE -o /dev/null "$base/versions/$id"; then
    echo "  deleted $label"
    deleted_ids+=("$id")
  else
    echo "::warning::Failed to delete version $id ($created)."
    failures=$((failures + 1))
  fi
done <<<"$doomed"

# ------------------------------------------------------------------ report

deleted_count="${#deleted_ids[@]}"
[ "$dry_run" = "true" ] && deleted_count=0

{
  echo "deleted-count=$deleted_count"
  echo "deleted-ids=${deleted_ids[*]:-}"
  echo "kept-count=$((total - ${#deleted_ids[@]}))"
} >>"$GITHUB_OUTPUT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ghcr-prune"
    echo
    if [ "$dry_run" = "true" ]; then
      echo "**Dry run** — nothing was deleted."
      echo
    fi
    echo "| | |"
    echo "|---|---|"
    echo "| Package | \`$owner/$package\` ($package_type) |"
    echo "| Versions found | $total |"
    echo "| Kept | $((total - ${#deleted_ids[@]})) |"
    echo "| $([ "$dry_run" = "true" ] && echo "Would delete" || echo "Deleted") | ${#deleted_ids[@]} |"
    [ "$failures" -gt 0 ] && echo "| Failed | $failures |"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$failures" -eq 0 ] || fail "$failures version(s) could not be deleted."

echo "Done."
