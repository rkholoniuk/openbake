# OpenBake

Open-source dev workspaces baked with Ansible, run with Docker and OpenTofu.

**You only need Docker** (≥ 25 with buildx: Docker Desktop, OrbStack, Colima or Docker Engine),
plus `make` and `git`. Ansible runs *inside* the image build and never ends up in an image.

Status: early. Building images works today. Running workspaces with `make up` (OpenTofu) and
setting up real machines with `make host` are next.

## Images

| Image | Contents |
|---|---|
| `ws-minimal` | Ubuntu 24.04, user `user` (uid 1000), core packages, git, tini, ripgrep, fd, bat, tmux, direnv, jq, yq, gh |
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

## Sandbox (experimental)

Runs `ws-agent` with no internet and no real credentials. A second container, the broker, is the
only way out: it forwards LLM API calls and adds the real key, which the agent never sees. See
[`sandbox/`](sandbox/) and the [broker requirements draft](docs/design/broker-requirements.md).

```sh
make image PROFILE=agent
mkdir -p ~/.config/openbake/sandbox/secrets
# put an Anthropic API key, or the token from `claude setup-token`, in
# ~/.config/openbake/sandbox/secrets/llm_key
make sandbox-up
make sandbox-check      # boundary tests: fails on any leak
make sandbox-shell      # then: claude -p "say hi"
make sandbox-down       # the agent's home volume is kept
```

Local state stays outside the repository, in `~/.config/openbake/sandbox/` (`SANDBOX_STATE_DIR`
moves it): `secrets/llm_key` is the real credential, and `exchange/` is shared with the agent as
`/exchange`, so treat its contents as untrusted. Only the Anthropic API is reachable today:
package installs and Codex need the egress proxy that is still to come.

### macOS: Apple `container` instead of Docker

`SANDBOX_RUNTIME=apple` runs the agent and the broker with Apple's
[`container`](https://github.com/apple/container), which gives each container its own lightweight
VM. It needs Apple silicon and macOS 26. This backend is experimental (tested with `container`
1.7.1 on macOS 26.3): trust `make sandbox-check`, not the fact that it started.

1. Check the macOS version: `sw_vers -productVersion` must print 26 or later.
2. Install `container`: download the signed `.pkg` from its
   [releases page](https://github.com/apple/container/releases) and open it.
3. Start its service once: `container system start`. Answer `Y` when it offers to install the
   default Linux kernel.
4. Build the agent image with Docker as usual (`make image PROFILE=agent`). `sandbox-up` copies it
   from Docker into `container`.
5. Run the sandbox:

```sh
make sandbox-up SANDBOX_RUNTIME=apple
make sandbox-check SANDBOX_RUNTIME=apple
make sandbox-shell SANDBOX_RUNTIME=apple
make sandbox-down SANDBOX_RUNTIME=apple
```

Differences from the Docker backend: the internal network still lets the agent reach the Mac
itself (Docker's does not), and there is no `no-new-privileges` option, so capabilities are
dropped instead. Image builds, `make check` and `make scan` still need Docker.

## Keeping images patched

A normal `make image` reuses cached layers, so it does **not** pick up new security updates.

```sh
make refresh PROFILE=devbox   # no cache: pinned base + today's security updates, then smoke, check, scans
```

CI runs `make refresh` for every image each Monday and opens an issue if a fresh build, check
mode or the Trivy/OSV gates fail. Don't `apt upgrade` inside a running workspace: only `/home/user`
survives a rebuild, so refresh the image instead.

## How it works

```text
images/Dockerfile   os ─► ansible (venv, bind-mounted only)
                    os ─► minimal ─► runtimes ─► devbox | data | agent
                    any ─► custom
ansible/apply.sh    runs roles: apply.sh base,git -e ws_target=image
ansible/roles/      base git cli_tools runtimes neovim code_server postgres data_sample agents
ansible/profiles/   minimal devbox data agent: roles in layer order, allowed targets, vars, ports
```

Each role runs in its own `RUN` step, so editing one role rebuilds only the layers from that role
on. apt, npm, pip/uv and download caches are BuildKit cache mounts. The same roles will also set up
real Ubuntu machines (`ws_target=host`), which is why they are Ansible and not plain Dockerfile
steps.

## Repository layout

```text
ansible/        apply.yml, apply.sh, ansible.cfg, roles/, profiles/ (one file per image/host setup)
custom/roles/   your roles for `make custom`
images/         Dockerfile, docker-bake.hcl, smoke.sh
sandbox/        compose.yaml, sandbox.sh, broker/: agent without internet or real credentials
docs/           design, guidelines, security policy
```

## Docs

- [Phase 1 design](docs/design/phase1-design.md)

## License

[Apache-2.0](LICENSE).
