# ghcr-prune

Delete old GitHub Packages versions, keeping the newest N.

GitHub Packages has no retention policy of its own: every push adds a version that lives forever and counts against your storage quota. This action trims them.

```yaml
- uses: NikoDyring/ghcr-prune@v1
  with:
    keep-last: 3
```

## Why another one of these

The widely used [`actions/delete-package-versions`](https://github.com/actions/delete-package-versions) is a **JavaScript** action — `using: node20`. GitHub deprecates Node runtimes every couple of years, and each deprecation needs the maintainer to re-bundle `dist/`. That action's last release was January 2024, its last commit June 2025, and [issue #240 (“Node.js 20 actions are deprecated”)](https://github.com/actions/delete-package-versions/issues/240) is open and unaddressed. It still runs, because GitHub force-migrates it to a newer Node, but it's on borrowed time.

`ghcr-prune` is a **composite** action: `using: composite`, plain shell and `curl`. There is no runtime declaration, so there is nothing to deprecate. It cannot rot the same way.

The tradeoff is honest: composite actions run on the runner's own tooling, so this one needs `curl` plus either `jq` or `python3`. Every GitHub-hosted runner has all three. On a self-hosted runner you may need to install one — the action fails with a clear message rather than misbehaving if neither parser is present.

## Usage

Trim a container image to its 3 newest versions after a deploy:

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
| `keep-last` | `3` | How many of the newest versions to keep. Must be ≥ 1. |
| `dry-run` | `false` | Log what would be deleted and delete nothing. |
| `token` | `${{ github.token }}` | Needs `packages: write` on the package. |

Versions are ordered newest-first by creation time, and everything past `keep-last` is deleted.

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

This action deliberately does **not** reimplement `delete-only-untagged-versions`, `num-old-versions-to-delete`, `ignore-versions` or `delete-only-pre-release-versions`. Keeping the newest N covers the common case; if you need one of the others, open an issue and say what you're doing with it.

## Behaviour worth knowing

- If the package has `keep-last` versions or fewer, nothing is deleted and the action succeeds.
- If the package has no versions at all, the action succeeds rather than failing.
- Individual delete failures are logged as warnings and the step fails at the end with a count, so one permission-denied version doesn't hide the rest.
- Deleting a package version is **not reversible**. Use `dry-run: true` first.
- Versions are ordered by `created_at`, with the version id breaking ties so that images pushed in the same second get a stable order.
- Set `GHCR_PRUNE_JSON=jq` or `GHCR_PRUNE_JSON=python3` in the step's `env` to force a parser, if a runner's `jq` is broken or you want to pin the behaviour.

## Requirements

`bash`, `curl`, and either `jq` or `python3`. All present on every GitHub-hosted runner. On a self-hosted runner, install one of the two parsers — the action fails with an explicit message if neither is found.

## Licence

MIT
