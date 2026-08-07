#!/usr/bin/env bash
#
# Delete old GitHub Packages versions, keeping the newest N deploys.
#
# Deliberately plain shell + curl: a composite action has no `using: nodeXX`
# runtime, so it can never be deprecated out from under its users the way
# JavaScript actions are. The only cost is needing a JSON parser on the
# runner, which is why jq and python3 are both accepted below.
#
# "Deploy" rather than "version" is the unit on purpose. For a container
# package the two are not the same: a multi-platform push publishes an index
# manifest plus one child manifest per platform, plus provenance and SBOM
# attestations if buildx made them. The Packages API lists every one of those
# as a sibling version and records no parent link, so counting versions would
# make `keep-last: 3` mean "one deploy and change" on a two-platform build.
# The registry is the only place the parent/child relationship exists, so for
# container packages this script reads it from there.

set -euo pipefail

api="${GITHUB_API_URL:-https://api.github.com}"
owner="${INPUT_OWNER:-}"
package="${INPUT_PACKAGE:-}"
package_type="${INPUT_PACKAGE_TYPE:-container}"
keep="${INPUT_KEEP_LAST:-3}"
dry_run="${INPUT_DRY_RUN:-false}"
token="${INPUT_TOKEN:-}"

# Where the container manifests live. Overridable for GitHub Enterprise, which
# serves its registry from its own host, and for the test suite.
registry="${GHCR_PRUNE_REGISTRY:-https://ghcr.io}"

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
[ "$keep" -ge 1 ] || fail "keep-last must be 1 or more (refusing to delete every deploy)."

case "$dry_run" in
true | false) ;;
*) fail "dry-run must be true or false, got '$dry_run'." ;;
esac

# A scoped npm name like @scope/pkg has to be encoded for the path segment.
package_path="${package//\//%2F}"

# Registry paths are lowercase-only, and an owner like `NikoDyring` is not.
image="$(printf '%s/%s' "$owner" "$package" | tr '[:upper:]' '[:lower:]')"

# Only container packages have the index/child split. For npm, maven, rubygems
# and nuget one publish really is one version, so those keep counting versions.
if [ "$package_type" = container ]; then
  unit="deploy"
else
  unit="version"
fi

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

# `.name` is the manifest digest on a container version, which is what ties a
# version to what the registry knows about it.
#
# Every parser is piped through `tr -d '\r'`. On a Windows runner both jq and
# python write their output in text mode, so each line arrives terminated with
# CRLF; the stray carriage return then rides along on the last field and turns
# a digest into one the registry has never heard of. Cheap to strip, and no
# value here can legitimately contain a CR.
if [ "$json_tool" = jq ]; then
  parse_versions() {
    jq -r '.[] | [.created_at, (.id | tostring), (.name // ""), ((.metadata.container.tags // []) | join(","))] | @tsv' | tr -d '\r'
  }
  parse_owner_type() { jq -r '.type // empty' | tr -d '\r'; }
  parse_manifest_children() { jq -r '.manifests[]?.digest // empty' | tr -d '\r'; }
else
  parse_versions() {
    "$json_tool" -c '
import json, sys
for v in json.load(sys.stdin):
    tags = ((v.get("metadata") or {}).get("container") or {}).get("tags") or []
    print("{}\t{}\t{}\t{}".format(v["created_at"], v["id"], v.get("name") or "", ",".join(tags)))
' | tr -d '\r'
  }
  parse_owner_type() {
    "$json_tool" -c 'import json,sys; print(json.load(sys.stdin).get("type",""))' | tr -d '\r'
  }
  parse_manifest_children() {
    "$json_tool" -c '
import json, sys
for m in json.load(sys.stdin).get("manifests") or []:
    if m.get("digest"):
        print(m["digest"])
' | tr -d '\r'
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
echo "Pruning $package_type package '$package' owned by $owner ($scope), keeping the newest $keep ${unit}(s)."

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

no_op() {
  echo "$1"
  {
    echo "deleted-count=0"
    echo "deleted-ids="
    echo "kept-count=$2"
  } >>"$GITHUB_OUTPUT"
  exit 0
}

if [ "$total" -eq 0 ]; then
  no_op "No versions found; nothing to do." 0
fi

# Newest first. ISO-8601 sorts correctly as text; id breaks ties so that
# versions pushed in the same second get a stable order.
sorted="$(printf '%s\n' "$versions" | sort -t"$(printf '\t')" -k1,1r -k2,2nr)"

# ------------------------------------------------------- which ones survive

# The set of digests that must not be deleted, newline-delimited with a
# leading and trailing newline so a match is always exactly bounded. Doubles
# as the visited set for the manifest walk.
protected=$'\n'

protect() {
  case "$protected" in
  *$'\n'"$1"$'\n'*) ;;
  *) protected="$protected$1"$'\n' ;;
  esac
}

is_protected() {
  case "$protected" in
  *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

if [ "$package_type" != container ]; then
  doomed="$(printf '%s\n' "$sorted" | tail -n +$((keep + 1)))"
  deploy_note=""
else
  registry_token="$(printf '%s' "$token" | base64 | tr -d '\n')"

  registry_get() {
    curl -sS --fail-with-body \
      -H "Authorization: Bearer $registry_token" \
      -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
      "$registry/v2/$image/manifests/$1"
  }

  # Breadth-first from one deploy's manifest, protecting every digest it
  # reaches. An index lists its per-platform children (and buildx's
  # attestations) under `.manifests`; a plain image manifest lists nothing and
  # simply terminates the walk. Non-zero means a fetch or parse failed and the
  # result is incomplete — the caller has to assume the worst.
  walk_manifest() {
    local queue="$1" digest body kids
    while [ -n "$queue" ]; do
      digest="${queue%%$'\n'*}"
      if [ "$queue" = "$digest" ]; then
        queue=""
      else
        queue="${queue#*$'\n'}"
      fi

      [ -n "$digest" ] || continue
      if is_protected "$digest"; then
        continue
      fi
      protect "$digest"

      body="$(registry_get "$digest" 2>/dev/null)" || return 1
      kids="$(printf '%s' "$body" | parse_manifest_children 2>/dev/null)" || return 1
      if [ -n "$kids" ]; then
        queue="$kids"$'\n'"$queue"
      fi
    done
  }

  # A tagged version is a deploy. Untagged ones are the machinery underneath.
  deploy_total=0
  untagged_total=0
  keep_digests=""
  while IFS=$'\t' read -r created id digest tags; do
    [ -n "$id" ] || continue
    if [ -z "$tags" ]; then
      untagged_total=$((untagged_total + 1))
      continue
    fi
    deploy_total=$((deploy_total + 1))
    if [ "$deploy_total" -le "$keep" ]; then
      keep_digests="$keep_digests$digest"$'\n'
    fi
  done <<<"$sorted"

  if [ "$deploy_total" -eq 0 ]; then
    echo "::warning::No tagged versions, so there are no deploys to count. Refusing to delete anything."
    no_op "Nothing to prune." "$total"
  fi

  # With nothing untagged there is no parent/child puzzle to solve, so skip
  # the registry entirely — a single-platform build never needs it, and this
  # keeps its failure modes out of the common case.
  resolved=true
  if [ "$untagged_total" -gt 0 ]; then
    while IFS= read -r digest; do
      [ -n "$digest" ] || continue
      if ! walk_manifest "$digest"; then
        resolved=false
        break
      fi
    done <<<"$keep_digests"
  fi

  # Idempotent, and the safety net if the walk bailed part-way through.
  while IFS= read -r digest; do
    [ -n "$digest" ] || continue
    protect "$digest"
  done <<<"$keep_digests"

  # Fail closed: an untagged version we could not attribute to a deploy might
  # be a child of one we are keeping, and deleting it would leave a kept image
  # unpullable. Leftover storage is the recoverable mistake; a broken rollback
  # target is not.
  if [ "$resolved" = false ]; then
    echo "::warning::Could not read manifests from $registry, so untagged versions can't be matched to a deploy. Keeping every untagged version; older deploys are still pruned. Check the token has \`packages: read\` on $image."
    while IFS=$'\t' read -r created id digest tags; do
      [ -n "$tags" ] || protect "$digest"
    done <<<"$sorted"
  fi

  doomed=""
  while IFS=$'\t' read -r created id digest tags; do
    [ -n "$id" ] || continue
    if is_protected "$digest"; then
      continue
    fi
    doomed="$doomed$created"$'\t'"$id"$'\t'"$digest"$'\t'"$tags"$'\n'
  done <<<"$sorted"
  doomed="$(printf '%s' "$doomed" | grep . || true)"

  deploy_note=" across $deploy_total deploy(s)"
fi

doomed_count="$(printf '%s\n' "$doomed" | grep -c . || true)"

echo "Found $total version(s)$deploy_note; $doomed_count over the limit."

if [ "$doomed_count" -eq 0 ]; then
  no_op "Nothing to prune." "$total"
fi

# ------------------------------------------------------------------- prune

deleted_ids=()
failures=0

while IFS=$'\t' read -r created id digest tags; do
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
    [ "$package_type" = container ] && echo "| Deploys found | $deploy_total |"
    echo "| Kept | $((total - ${#deleted_ids[@]})) |"
    echo "| $([ "$dry_run" = "true" ] && echo "Would delete" || echo "Deleted") | ${#deleted_ids[@]} |"
    [ "$failures" -gt 0 ] && echo "| Failed | $failures |"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$failures" -eq 0 ] || fail "$failures version(s) could not be deleted."

echo "Done."
