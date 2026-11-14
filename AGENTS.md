# Instructions for coding agents

OpenBake builds dev workspace images from Ansible roles and will run them with OpenTofu. Read
[README.md](README.md) first, then the [phase 1 design](docs/design/phase1-design.md) for what is being
built and in which order.

## Rules

- **Docker is the only prerequisite.** Every tool runs in a container through a `make` target.
  Don't add steps that need Ansible, Python packages or other tools on the host.
- **CI is a thin wrapper over `make`.** New checks become a make target first, then a CI step
  that calls it. `make ci` must keep running the same steps as `.github/workflows/ci.yml`.
- **Ansible:** follow [docs/ansible-guidelines.md](docs/ansible-guidelines.md), especially
  idempotence, check mode and the secrets rules.
- **Pin everything:** GitHub Actions by full commit SHA (with the version in a comment),
  versions plus sha256 for downloads, exact versions for Python/npm tools, and no moving tags
  (`latest`, `stable`, `main`). Never use the `aquasecurity/trivy-action` or
  `setup-trivy` Actions (CVE-2026-33634).
- **Secrets:** never in build args, `WS_*` variables, role defaults, logs or commits.
- **Design changes:** update [docs/design/phase1-design.md](docs/design/phase1-design.md) in the
  same PR when behaviour differs from it.

## Before you finish

```sh
make lint
make ci PROFILE=minimal     # or the profiles your change touches
```
