# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/rkh0x7EA/openbake/security/advisories/new)
rather than in a public issue. Include what you found, how to reproduce it, and which image,
role or commit it affects.

We aim to acknowledge reports within 3 working days.

## Scope

- Ansible roles in `ansible/roles/` and the images built from them
- the build files in `images/`
- secrets handling (env files, build secrets, logs)

Vulnerabilities in upstream packages shipped in the images (Ubuntu, Node, Python packages, editors,
agent CLIs) should go to those projects. We fix them here by updating pins and rebuilding.

## Patching and scanning

- Every PR: Trivy fails on CRITICAL vulnerabilities that have a fix, and on secrets in any image
  layer; OSV-Scanner fails on any known malicious package in the images and lockfiles
  (`make scan`).
- Every Monday: all images are rebuilt from scratch with the newest Ubuntu base and current
  security updates, then smoke-tested, checked and scanned (`make refresh`,
  `.github/workflows/weekly.yml`). A failure opens an issue.
- Locally: `make refresh PROFILE=<image>` does the same for your images.

Planned: published images rebuilt weekly with signatures and SBOMs, a nightly rescan of published
images, and a malware scan.

## Supply chain

What we consume, how it is pinned, which gates run, how exceptions work and what we do when a
dependency is compromised: [docs/security/supply-chain-policy.md](docs/security/supply-chain-policy.md).

## Secrets

Never put API keys or tokens in build args, `WS_*` variables or role defaults. Build-time tokens
go through `docker buildx --secret` only. See section 6.5 of the
[phase 1 design](docs/design/phase1-design.md).
