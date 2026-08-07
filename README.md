# ghcr-prune

Delete old GitHub Packages versions, keeping the newest N deploys.

GitHub Packages has no retention policy of its own: every push adds a version that lives forever and counts against your storage quota. This action trims them.

```yaml
- uses: NikoDyring/ghcr-prune@v1
  with:
    keep-last: 3
```

`keep-last: 3` means three deploys you can roll back to — not three rows in the API.

## A deploy is not a version

For a single-platform image the two are the same thing and you can stop reading. For anything else they are not, and the difference is the whole reason this action exists in the shape it does.

A multi-platform push publishes an *index* manifest that points at one child manifest per platform, plus provenance and SBOM attestations if buildx made them. The Packages API lists every one of those as its own version: the index carries your tags, the children are untagged. A two-platform build with attestations is five versions for one `docker push`.

Count versions and `keep-last: 3` keeps one deploy and some debris. Worse, the naive fix — delete the untagged ones — deletes the per-platform manifests that the images you kept are made of, and leaves you with tags that resolve to nothing.

So `keep-last` counts **tagged versions**, and each one drags its children along:

1. Sort the tagged versions newest-first. Those are your deploys.
2. Keep the newest `keep-last` of them.
3. Read each kept deploy's manifest from the registry and protect every digest it references.
4. Delete everything else — older deploys, their children, and untagged manifests no surviving index points at.

Step 3 is the only part that needs the registry, and it is skipped entirely when every version is tagged. If it fails — token without registry access, a registry that isn't GHCR, a transient error — the action **keeps every untagged version** and warns, rather than guessing. Leftover storage is recoverable; a kept image you can't pull is not.

## Why another one of these

The widely used [`actions/delete-package-versions`](https://github.com/actions/delete-package-versions) is a **JavaScript** action — `using: node20`. GitHub deprecates Node runtimes every couple of years, and each deprecation needs the maintainer to re-bundle `dist/`. That action's last release was January 2024, its last commit June 2025, and [issue #240 (“Node.js 20 actions are deprecated”)](https://github.com/actions/delete-package-versions/issues/240) is open and unaddressed. It still runs, because GitHub force-migrates it to a newer Node, but it's on borrowed time.

`ghcr-prune` is a **composite** action: `using: composite`, plain shell and `curl`. There is no runtime declaration, so there is nothing to deprecate. It cannot rot the same way.

The tradeoff is honest: composite actions run on the runner's own tooling, so this one needs `curl` plus either `jq` or `python3`. Every GitHub-hosted runner has all three. On a self-hosted runner you may need to install one — the action fails with a clear message rather than misbehaving if neither parser is present.

## Usage

Trim a container image to its 3 newest deploys:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      # ... build and push your image ...

      - uses: NikoDyring/ghcr-prune@v1
        with:
          keep-last: 3
```

See what would go without deleting anything:

```yaml
- uses: NikoDyring/ghcr-prune@v1
  with:
    keep-last: 5
    dry-run: true
```

Prune a package the current repository doesn't own:

```yaml
- uses: NikoDyring/ghcr-prune@v1
  with:
    owner: my-org
    package: my-service
    keep-last: 10
    token: ${{ secrets.PACKAGES_TOKEN }}
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `package` | repository name | Package name. Scoped npm names (`@scope/pkg`) are encoded for you. |
| `owner` | repository owner | User or organisation owning the package. User vs org is detected automatically. |
| `package-type` | `container` | One of `container`, `npm`, `maven`, `rubygems`, `nuget`. |
| `keep-last` | `3` | How many of the newest deploys to keep. Must be ≥ 1. |
| `dry-run` | `false` | Log what would be deleted and delete nothing. |
| `token` | `${{ github.token }}` | Needs `packages: write` on the package. |

Deploys are ordered newest-first by creation time, and everything past `keep-last` is deleted.

`GHCR_PRUNE_REGISTRY` in the step's `env` overrides the registry host, which defaults to `https://ghcr.io`. Set it if you are on GitHub Enterprise Server, whose registry lives on its own hostname.

## Outputs

| Output | Description |
|---|---|
| `deleted-count` | Number of versions deleted. Always `0` on a dry run. |
| `deleted-ids` | Space-separated version ids deleted (or that would be, on a dry run). |
| `kept-count` | Number of versions retained. |

The action also writes a summary table to the job summary.

## Permissions

The job needs `packages: write`:

```yaml
permissions:
  packages: write
```

The default `GITHUB_TOKEN` can manage packages owned by the same repository. For a package owned by a different user or org, supply a PAT with `write:packages` via `token:`.

The same token is used to read manifests from the registry. `packages: write` and `write:packages` both include read access, so there is nothing extra to grant — but a token scoped narrowly enough to delete versions and not pull manifests will trip the fail-closed path and leave untagged versions behind, with a warning saying so.

## Migrating from `actions/delete-package-versions`

```diff
-- uses: actions/delete-package-versions@v5
-  with:
-    package-name: my-image
-    package-type: container
-    min-versions-to-keep: 3
+- uses: NikoDyring/ghcr-prune@v1
+  with:
+    package: my-image
+    package-type: container
+    keep-last: 3
```

`package-name` → `package`, `min-versions-to-keep` → `keep-last`. Both are optional here: `package` defaults to the repository name.

**The numbers do not mean the same thing.** `min-versions-to-keep: 3` keeps three *versions*; `keep-last: 3` keeps three *deploys*. On a single-platform image that is the same set. On a multi-platform image you will keep considerably more, which is the point — run it with `dry-run: true` once after migrating and read the counts.

This action deliberately does **not** reimplement `delete-only-untagged-versions`, `num-old-versions-to-delete`, `ignore-versions` or `delete-only-pre-release-versions`. Keeping the newest N covers the common case; if you need one of the others, open an issue and say what you're doing with it.

## Behaviour worth knowing

- If the package has `keep-last` deploys or fewer, no deploy is deleted — but untagged manifests that no surviving index references are still collected.
- If the package has no versions at all, the action succeeds rather than failing.
- If the package has no *tagged* versions, there are no deploys to count, so the action refuses to delete anything and says so.
- Only `container` packages have the index/child split. For `npm`, `maven`, `rubygems` and `nuget` one publish is one version, so those keep counting versions and never touch the registry.
- Individual delete failures are logged as warnings and the step fails at the end with a count, so one permission-denied version doesn't hide the rest.
- Deleting a package version is **not reversible**. Use `dry-run: true` first.
- Versions are ordered by `created_at`, with the version id breaking ties so that images pushed in the same second get a stable order.
- Set `GHCR_PRUNE_JSON=jq` or `GHCR_PRUNE_JSON=python3` in the step's `env` to force a parser, if a runner's `jq` is broken or you want to pin the behaviour.

## Requirements

`bash`, `curl`, and either `jq` or `python3`. All present on every GitHub-hosted runner. On a self-hosted runner, install one of the two parsers — the action fails with an explicit message if neither is found.

## Licence

MIT
