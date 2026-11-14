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

## Secrets

Never put API keys or tokens in build args, `WS_*` variables or role defaults. Build-time tokens
go through `docker buildx --secret` only. See section 6.5 of the
[phase 1 design](docs/design/phase1-design.md).
