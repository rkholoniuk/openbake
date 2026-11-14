# Contributing

Thanks for helping. OpenBake is early, so please open an issue before large changes.

## Setup

Docker ≥ 25 with buildx, `make` and `git`. Nothing else.

```sh
make image PROFILE=minimal && make smoke PROFILE=minimal   # fastest loop
make image && make smoke                                    # everything CI builds
```

## Changing a role

- One role installs or configures one thing. Keep roles idempotent: a second run must report no
  changes (`changed_when` must reflect real changes, never `true`).
- Every download needs a checksum (being enforced from M3 with `versions.yml`).
- Tasks that touch secrets use `no_log: true` and `diff: false`; secret variables are named
  `secret_*` or `vault_*`.
- If a role adds a tool, add a check to `images/smoke.sh`.

## Pull requests

- Keep PRs focused; describe what changed and how you tested it.
- CI must pass: lint, image builds and smoke tests on amd64 and arm64.
- By contributing you agree that your contributions are licensed under Apache-2.0.
