# Contributing

Small project, simple rules.

## Running the tests

```bash
bash tests/validation.sh   # input validation, offline
bash tests/fake-api.sh     # end to end against a local stand-in for the API
```

Both need `bash`, `curl` and either `jq` or `python3`. `tests/fake-api.sh` additionally needs `python3` to serve the fixtures.

Force a specific JSON parser to check both code paths:

```bash
GHCR_PRUNE_JSON=jq      bash tests/fake-api.sh
GHCR_PRUNE_JSON=python3 bash tests/fake-api.sh
```

CI runs both suites against both parsers.

## Formatting and linting

```bash
shellcheck prune.sh tests/*.sh
shfmt -i 2 --diff prune.sh tests/*.sh
```

**Two-space indentation**, hence `-i 2` — shfmt's default is tabs. Both are enforced in CI.

## Testing strategy, and its one gap

`tests/fake-api.sh` runs the real script against a local server standing in for both the GitHub API and the container registry. That covers pagination, JSON parsing, newest-first ordering, deploy grouping and version selection — deliberately in dry-run, so the suite never issues a `DELETE`.

The main fixture is a multi-platform package on purpose: three deploys, each an index manifest plus per-platform children, plus one orphaned untagged manifest. That is the case where "keep the newest N versions" and "keep the newest N deploys" disagree, and where getting it wrong deletes a child manifest and leaves a kept image unpullable. The suite also covers a package where every version is tagged (the registry must never be consulted), a package with no tags at all (nothing may be deleted), and an unreachable registry (fail closed: keep every untagged version, prune older deploys anyway).

The `wiring` CI job runs the action through `action.yml` to catch broken input mapping. Because this repo ships an action rather than an image, it has no container package, so that job can only reach the "package not found" path. It asserts that explicitly rather than using `continue-on-error` to wave a failure through.

**The gap: no test performs a successful prune against the real API.** Closing it means publishing a throwaway container package with several versions and pruning that, which trades a permanently-published fixture package for the coverage. If you take that on, make it dry-run first and assert the selection before letting it delete anything.

## Pull requests

- Keep the scope narrow. Options omitted from v1 (`untagged-only`, age-based pruning, tag filters) are omissions rather than oversights; say what you need one for.
- Any behaviour change needs a test in `tests/fake-api.sh`.
- Deleting a package version is irreversible, so err toward refusing to act on ambiguous input.
