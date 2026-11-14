# OpenBake

Open-source dev workspaces baked with Ansible, run with Docker and OpenTofu.

With only Docker, make and git installed, OpenBake will let you:

- **bake** workspace images from Ansible roles (Neovim, code-server, language runtimes, AI coding
  agents);
- **run** workspaces from them on a local or remote Docker host, with a home volume that survives
  stops and image updates;
- **set up** a real Ubuntu 24.04 laptop or server with the same roles, including firewall, SSH
  hardening and automatic security updates.

Status: design. Nothing is implemented yet.

- [Phase 1 design](docs/design/phase1-design.md)

License: [Apache-2.0](LICENSE).
