# OpenBake

Open-source dev workspaces baked with Ansible, run with Docker and OpenTofu.

**You only need Docker** (≥ 25 with buildx: Docker Desktop, OrbStack, Colima or Docker Engine),
plus `make` and `git`. Ansible runs *inside* the image build and never ends up in an image.

Status: early. Building images works today. Running workspaces with `make up` (OpenTofu) and
setting up real machines with `make host` are next.

## Images

| Image | Contents |
|---|---|
| `ws-minimal` | Ubuntu 24.04, user `user` (uid 1000), core packages, git, tini |
| `ws-devbox` | minimal + Python and Node (mise), uv, Neovim + LazyVim (plugins pre-installed), code-server |
| `ws-data` | minimal + Python, uv, PostgreSQL 16, a Streamlit + Dagster sample pipeline |
| `ws-agent` | minimal + Python, Node, Codex and Claude Code CLIs |
| `ws-custom` | any of the above plus your own roles from `custom/roles/` |

## Quick start

```sh
git clone https://github.com/rkh0x7EA/openbake && cd openbake
make image                         # devbox, data, agent for this machine
make image PROFILE=agent           # or just one
make smoke PROFILE=agent           # check it
make run-devbox PASSWORD=secret    # code-server on http://127.0.0.1:13337 (temporary until `make up`)
```

Your own roles:

```sh
cp -r custom/roles/hello_custom custom/roles/my_role    # edit it
make custom FROM=devbox ROLES=my_role                   # -> ws-custom:local
```

Pick versions with `WS_*` variables (they are listed in
[images/docker-bake.hcl](images/docker-bake.hcl); `versions.yml` replaces them in M3):

```sh
WS_PYTHON_VERSIONS='["3.13","3.12"]' WS_NODE_VERSIONS='["24"]' make image PROFILE=devbox
```

## How it works

```text
images/Dockerfile   os ─► ansible (venv, bind-mounted only)
                    os ─► minimal ─► runtimes ─► devbox | data | agent
                    any ─► custom
ansible/apply.sh    runs roles: apply.sh base,git -e ws_target=image
ansible/roles/      base git runtimes neovim code_server postgres data_sample agents
```

Each role runs in its own `RUN` step, so editing one role rebuilds only the layers from that role
on. apt, npm, pip/uv and download caches are BuildKit cache mounts. The same roles will also set up
real Ubuntu machines (`ws_target=host`), which is why they are Ansible and not plain Dockerfile
steps.

## Repository layout

```text
ansible/        apply.yml, apply.sh, ansible.cfg, roles/
custom/roles/   your roles for `make custom`
images/         Dockerfile, docker-bake.hcl, smoke.sh
docs/           design, guidelines, security policy
```

## Docs

- [Phase 1 design](docs/design/phase1-design.md)

## License

[Apache-2.0](LICENSE).
