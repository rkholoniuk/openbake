# OpenBake phase 1: open-source dev workspaces with Ansible, Docker and OpenTofu

*2026-11-14. Status: design, revision 3 (after three review rounds, section 11).
"ad" = agent-day, one day of agent implementation work.*

## 1. Overview

OpenBake is one open-source repository (Apache-2.0, see `LICENSE` and `NOTICE`). With **Docker, make and git**
installed, a developer can:

1. **bake workspace images** whose contents are defined by Ansible roles;
2. **start a workspace** from one of those images on a local or remote Docker host (`make up`;
   OpenTofu does the provisioning);
3. **set up a whole Ubuntu 24.04 machine** (laptop or server) with the same roles, including
   firewall, SSH hardening and automatic security updates.

Every tool (OpenTofu, Ansible, Docker build tools, scanners) runs inside a pinned **runner
container**, so nothing else has to be installed (section 6.8). Phase 1 has no control-plane
server, no UI and no custom Terraform provider. It grows out of an earlier spike
which proved per-role image layers.

## 2. Glossary

| Term | Meaning |
|---|---|
| **Role** | One Ansible role in `ansible/roles/`; installs or configures one thing |
| **Profile** | A named, ordered list of roles plus variables, in `ansible/profiles/<name>.yml`. The profile name is the single key for an image, a host setup and a workspace |
| **Target** | Where Ansible applies a profile: `image` (inside `docker build`) or `host` (a real machine). Profiles list allowed targets; roles assert supported targets |
| **Image** | A Docker image built from an `image`-target profile: `ws-<profile>` |
| **Workspace** | One container plus its home volume, created by the Docker template |
| **Template** | The OpenTofu configuration in `templates/docker/` |
| **Docker endpoint** | The daemon address of the active Docker context (`docker context inspect`), or `DOCKER_HOST` if set |
| **Host ID** | First 12 hex characters of sha256 of the Docker endpoint. Separates state per daemon |
| **Env file** | The workspace's secrets file, `~/.config/ws/<host-id>/<name>.env` (section 6.5) |
| **Runner** | `ws-runner` image with pinned Ansible, OpenTofu, Docker CLI + buildx, scanners. `make` runs every tool in it unless `NATIVE=1` |
| **`ws-init`** | Image entrypoint: seeds an empty home once, loads the env file, runs the command |
| **Coder dotfiles convention** | Clone a dotfiles repo; run the first executable of `install.sh, install, bootstrap.sh, bootstrap, setup.sh, setup`; if none, symlink its top-level dotfiles into `$HOME` (existing files moved to `*.bak`) |

## 3. Problem statement

The spike showed per-role image layers work: a no-change rebuild of three images took 1 s and a
one-role change about 45 s on a 2-vCPU sandbox. Missing:

- **Running workspaces:** only `docker run` lines; nothing keeps volume, ports and environment
  together; no remote hosts.
- **Real machines:** the spike roles assume a container build. On a real machine `base` would
  delete the `ubuntu` login user and grant passwordless sudo. No firewall, SSH or update roles.
- **Supply chain:** several downloads have no checksum or a moving version; nothing scans, signs
  or rebuilds images.

## 4. Goals and non-goals

### 4.1 Goals

| # | Goal | Measured by |
|---|---|---|
| G1 | Build 4 images from profiles (`minimal`, `devbox`, `data`, `agent`), amd64 and arm64 | `make image` + `make smoke` in CI on both architectures |
| G2 | Start, stop, delete a workspace; home data survives stop **and** an image update | `tofu test` (section 6.7) |
| G3 | The same template works on a remote Docker host | CI job with `DOCKER_HOST=ssh://` |
| G4 | Set up this machine or a remote Ubuntu 24.04 server; second run reports 0 changes; the operator keeps SSH access | `host.yml` jobs |
| G5 | Images and the runner are pinned, scanned, signed and rebuilt weekly; signatures are verified before use | `images.yml`, `rescan.yml`, `make` verification (6.8) |
| G6 | No sentinel secret value appears in build logs, Ansible logs, image layers or OpenTofu state | `tests/secrets-sentinel.sh` passes; its negative control is detected |
| G7 | `git clone` to a running workspace in under 10 minutes, excluding image downloads, with only Docker, make and git installed | timed by hand on a clean Ubuntu 24.04 VM and a Mac |

### 4.2 Later (section 9)

Kubernetes, Docker Compose and Packer templates; installing software into running workspaces;
control plane, UI, accounts and platform roles, custom Terraform provider and workspace agent.

### 4.3 Out of scope

The Terraform binary (the template uses standard HCL but only OpenTofu is tested); distros other
than Ubuntu 24.04; macOS as an Ansible target (a Mac can run `make up` and `make image`); desktop
editors; antivirus on hosts; Falco.

## 5. User journeys

### J1: ready-made workspace

```sh
git clone https://github.com/rkh0x7EA/openbake && cd openbake
make up PROFILE=devbox        # pulls + verifies runner and image, creates the env file with a
                              # random PASSWORD if missing, starts the container
make password NAME=devbox     # shows the code-server password
make shell NAME=devbox        # docker exec -it ws-devbox bash -l
make stop NAME=devbox         # container removed, home volume kept
make down NAME=devbox         # confirm (CONFIRM=yes skips); deletes container + volume
```

### J2: remote Docker host

`DOCKER_HOST=ssh://me@build-box make up PROFILE=agent`. State goes to `.state/<host-id>/agent/`.
The env file is copied to the remote host (6.5). Ports bind to `127.0.0.1` on the remote host;
reach them with `ssh -L`.

### J3: own image

`make custom FROM=devbox ROLES=my_role` (role in `custom/roles/`) builds `ws-custom:local`;
`make up PROFILE=devbox IMAGE=ws-custom:local`. For a remote host, push it to a registry or
`docker save | ssh host docker load` first.

### J4: this laptop (Ubuntu)

`make host PROFILE=workstation`. The runner connects back to this machine over SSH (6.8), so the
machine needs `openssh-server` and the user's key in `~/.ssh/authorized_keys`. It asks for the
sudo password once. Without an SSH server: `./bootstrap.sh`, then
`make host PROFILE=workstation NATIVE=1`.

### J5: remote server

Copy `ansible/inventories/example/` to `ansible/inventories/mylab/` (git-ignored), add hosts,
then `make host PROFILE=hardened-server INVENTORY=ansible/inventories/mylab`.

## 6. Technical design

### 6.0 Tool split: OpenTofu provisions, Ansible configures

- **OpenTofu** owns things that are *created and destroyed*: workspace containers and volumes
  (phase 1), later VMs, networks, Kubernetes namespaces and cloud resources. It keeps state, and
  drift is shown with `tofu plan -refresh-only`.
- **Ansible** owns what runs *inside* them: packages, config files, users, services, in images
  (`ws_target=image`) and on machines (`ws_target=host`). It is stateless and idempotent; drift is
  shown with `ansible-playbook --check --diff`.
- **Hand-off** (when templates create machines, phase 2+): OpenTofu outputs render an inventory
  with `local_file` into `ansible/inventories/<env>/` (git-ignored); `make host` runs against it
  after `wait_for_connection` (no fixed sleeps). No `local-exec`/remote-exec provisioners running
  Ansible from inside OpenTofu.
- **Immutable path:** the same roles bake images (Docker now, Packer AMIs later) that OpenTofu
  deploys unchanged. Prefer it over configuring long-lived machines where possible.

### 6.1 Repository layout

```text
openbake/
├── README.md  LICENSE  NOTICE  SECURITY.md  CONTRIBUTING.md  .gitignore (.state/ .tools/)
├── .ansible-lint  .yamllint  .gitleaks.toml
├── Makefile                 # image smoke custom up stop down ls shell password host
├── bootstrap.sh             # NATIVE=1 tools: uv → .tools/venv (ansible-core, PyYAML); OpenTofu → .tools/bin
├── versions.yml             # every pinned version, URL template, sha256 (6.2)
├── renovate.json
├── ansible/
│   ├── ansible.cfg  apply.yml  apply.sh
│   ├── profiles/            # minimal devbox data agent workstation hardened-server
│   ├── roles/               # base git cli_tools runtimes neovim code_server postgres data_sample
│   │                        # agents dotfiles firewall hardening auto_updates automation_account
│   │   ├── agents/files/{package.json,package-lock.json}
│   │   ├── runtimes/files/{mise.lock,uv-requirements.txt}
│   │   └── neovim/files/{lazy-lock.json,init.lua}
│   ├── lint/ws_secret_no_log.py
│   └── inventories/  local/  test/  example/   # real ones (production/…) are git-ignored
├── images/  Dockerfile  docker-bake.hcl  smoke.sh
├── templates/docker/  versions.tf  main.tf  variables.tf  outputs.tf  .terraform.lock.hcl
│                       README.md  tests/docker.tftest.hcl
├── custom/roles/            # users' roles for `make custom`
├── runner/  Dockerfile  ws-runner-init
├── security/  trivy.yaml  ignore.yaml  check-ignores.py  ratchet.py
├── scripts/  check-pins.py  update-checksums.py  profiles-consistency.py  docker-endpoint.sh
├── tests/  idempotence.sh  secrets-sentinel.sh  roles/sentinel_leak/
├── docs/  design/  roles.md  security.md
└── .github/workflows/  ci.yml  host.yml  images.yml  rescan.yml  checksums.yml
```

### 6.2 Profiles, values and the image stage graph

**Value precedence** (lowest first):
1. role `defaults/main.yml`;
2. `versions.yml`;
3. profile `vars`;
4. explicit overrides: `make host … VARS='<json>'` (passed as `-e`), or `make image … VARS='<json>'`.

`make image` overrides reach the build as the single build arg `WSV_EXTRA_VARS` (JSON), which
`apply.sh` passes as `-e`. The spike's per-version `WS_*`/`WSV_*` variables are removed. Bake keeps
`WS_REGISTRY`, `WS_TAG`, `WS_PLATFORMS`, `WS_BASE_IMAGE`, `WS_EXTRA_VARS` and the `WS_CUSTOM_*`
variables (`WSV_CUSTOM_VARS` stays for `make custom`).

**`versions.yml`** nests everything under one key, so it loads as a single variable:
```yaml
versions:
  code_server:
    version: "4.145.2"   # renovate: datasource=github-releases depName=coder/code-server
    url: "https://github.com/coder/code-server/releases/download/v{version}/code-server-{version}-linux-{arch}.tar.gz"
    arch: { amd64: amd64, arm64: arm64 }
    sha256: { amd64: "<hex>", arm64: "<hex>" }
    upstream_checksums: "https://github.com/coder/code-server/releases/download/v{version}/SHA256SUMS"  # optional
  code_server_extensions:
    ms-python.python: { version: "2026.10.0", sha256: "<hex>" }
  github_ssh_host_keys: ["github.com ssh-ed25519 AAAA…", "…"]
```
- **Loading:** `apply.yml` loads the file with `include_vars: { file: "{{ ws_versions_file }}", name: _v }`
  and uses `versions: "{{ _v.versions }}"`. `ws_versions_file` defaults to
  `{{ playbook_dir }}/../versions.yml`; `apply.sh` sets `/opt/ansible/versions.yml` in builds.
- **Checksums:** roles build `checksum: "sha256:{{ versions.<x>.sha256[ws_arch.deb] }}"`.
- **Extensions:** profiles list extension IDs only (`code_server_extensions: [ms-python.python]`).
  The version and sha256 come from `versions.code_server_extensions`, and `check-pins.py` fails if
  an ID has no entry there.

**In builds**, the Dockerfile's `ansible` stage copies `versions.yml` and `ansible/profiles/` into
`/opt/ansible/`. A change to either rebuilds every role layer. Accepted: images rebuild weekly, and
role edits still rebuild only from that role on.

**Image stage graph:**
```text
os ─► ansible        venv, apply.yml/apply.sh/ansible.cfg, versions.yml, profiles/
os ─► minimal        base, git, cli_tools                 USER user, CMD bash -l
minimal ─► runtimes  runtimes
runtimes ─► devbox   neovim, code_server                  CMD ws-code-server
runtimes ─► data     postgres, data_sample                CMD ws-sample-data start --foreground
runtimes ─► agent    agents                               CMD bash -l
any ─► custom        CUSTOM_ROLES                         -e ws_target=image
```

**Ansible calls in the Dockerfile:**
- Shared stages (`minimal`, `runtimes`) run `apply.sh <role> -e ws_target=image`.
- Final stages run `apply.sh <role> -e ws_target=image -e ws_profile=<p>`.
- `custom` runs `apply.sh "$CUSTOM_ROLES" -e ws_target=image`.

**Profiles** (role order = layer order):

| Profile | Targets | Roles | Ports |
|---|---|---|---|
| `minimal` | image | base, git, cli_tools | none |
| `devbox` | image, host | base, git, cli_tools, runtimes, neovim, code_server | 13337 |
| `data` | image | base, git, cli_tools, runtimes, postgres, data_sample | 3000, 8501 |
| `agent` | image, host | base, git, cli_tools, runtimes, agents | none |
| `workstation` | host | base, git, cli_tools, runtimes, neovim, agents, dotfiles, firewall, auto_updates | n/a |
| `hardened-server` | host | base, git, firewall, hardening, auto_updates | n/a |

```yaml
# ansible/profiles/devbox.yml
name: devbox
targets: [image, host]
roles: [base, git, cli_tools, runtimes, neovim, code_server]
vars:
  code_server_extensions: [ms-python.python]
workspace:
  ports: { code-server: 13337 }
```

**Shared-stage rule.** `base`, `git`, `cli_tools` and `runtimes` are shared by several images, so
they take image values only from `versions.yml` and role defaults. Image profiles may set `vars`
only for roles in their own final stage. Host profiles may set vars for any role.

**`scripts/profiles-consistency.py`** parses `images/Dockerfile`, follows each stage's `FROM`
chain and collects roles from the `apply.sh` lines, in order. It checks:
- every image profile's chain equals its `roles`, in order;
- every role named by an existing profile exists;
- the shared-stage rule;
- ports are integers;
- there is no `EXPOSE`, because ports live in profiles.

It also prints the chain up to each role, which `tests/idempotence.sh` uses as that role's
prerequisites.

**`apply.yml`:**
- `hosts: "{{ ws_hosts | default('localhost') }}"`;
- `ws_target` defaults to `host`;
- `ws_user` is `user` for `image` and `ansible_user_id` for `host`; `ws_home` comes from `getent`;
- **Role list:** when `ws_roles` is not given, it is read from the profile's `roles`.
- **Preflight:** stops if `ws_target` is not in the profile's `targets`.

**Roles** start with an assert that `ws_target` is in their `ws_role_targets` default:
- image-only: `postgres`, `data_sample`;
- host-only: `dotfiles`, `firewall`, `hardening`, `auto_updates`.

**`apply.sh`** uses `${WS_VENV:-$here/venv}`. **`ansible.cfg`** has a repo-relative `roles_path`
and keeps `/opt/roles` for builds.

**`make ping INVENTORY=…`** runs before any host change (and as the first step of `make host`):
`ansible.builtin.ping` on every host, then a read-only connectivity probe per host: DNS
resolution and outbound HTTPS to the hosts roles download from (`archive.ubuntu.com`,
`github.com`, `registry.npmjs.org`, `pypi.org`), over IPv4 and, when the host has a global IPv6
address, IPv6. Probes use `uri`/`command` with `changed_when: false`, `check_mode: false` and a
narrow `failed_when`, so they never change a host. Results are collected per host with
`set_fact` and written once (`run_once`, `delegate_to: localhost`) to
`.state/reports/connectivity-<inventory>.json`, plus a one-line summary per host. `make host`
stops early when a host is unreachable or can't reach a download source it needs.

**`make host`** runs:
```
ansible-playbook -i <INVENTORY or ansible/inventories/local> ansible/apply.yml \
  -e ws_profile=<P> -e ws_target=host -e ws_hosts=<LIMIT or all> -e '<VARS>' -K
```

### 6.3 Roles: image and host behaviour

| Role | `image` target | `host` target |
|---|---|---|
| `base` (spike, changed) | packages; removes stock `ubuntu` user; creates `user` uid 1000; sudo rule if `base_passwordless_sudo` (default true); installs `ws-init` and `/etc/profile.d/ws-env.sh`; manifest | packages and manifest only. **Never creates, deletes or changes users or sudo rules.** `ws_user` must already exist |
| `git` (spike, changed) | git, git-lfs; `git_known_hosts_source: static` default, keys from `versions.github_ssh_host_keys` | same |
| `cli_tools` (new) | apt: `ripgrep`, `fd-find` (+ link `/usr/local/bin/fd`), `jq`, `bat` (+ link `/usr/local/bin/bat` → `batcat`), `tmux`, `direnv`. Pinned binaries from `versions.yml`: `yq` (mikefarah), `gh`. Takes over the fd link task from `neovim`; `ripgrep`, `fd-find` and `jq` are removed from `agents_packages` and `neovim_packages` | same |
| `runtimes` (spike, changed) | mise (sha256) with `/etc/mise/mise.lock` and `lockfile = true` in `/etc/mise/config.toml`; uv from `files/uv-requirements.txt` with `pip install --require-hashes` | same |
| `neovim` (spike, changed) | Neovim pinned (version + sha256). LazyVim starter at a pinned commit plus plugins from `lazy-lock.json`, installed read-only under `/opt/ws/nvim`. `/usr/local/bin/nvim` is a wrapper that runs `nvim -u /opt/ws/nvim/init.lua` when the user has no `~/.config/nvim/init.lua`. lazy.nvim options: `checker.enabled=false`, `change_detection.enabled=false`, `install.missing=false`, `lockfile=/opt/ws/nvim/lazy-lock.json`, state and data writes under `~/.local/state` and `~/.local/share`. **Nothing is seeded into home**, so image updates reach the editor. A user `~/.config/nvim` replaces the shipped config completely (documented). T4 confirms the read-only setup with a spike; fallback: seed into home with a version marker | same |
| `code_server` (spike, changed) | code-server (sha256); extensions per 6.2, outside home; `ws-code-server` reads `PASSWORD` from the environment; binds `0.0.0.0` inside the container | binds `127.0.0.1`; no system service. Users run `ws-code-server`, which reads `PASSWORD` from `~/.config/ws/code-server.env` (0600; the role creates it with a random value, `no_log`) |
| `postgres` (spike, changed) | PostgreSQL 16 (Ubuntu packages), `ws-postgres`; the two `changed_when: true` tasks get real conditions | refused |
| `data_sample` (spike, changed) | sample seeded into `~/workspace` on first start; `uv sync --frozen` | refused |
| `agents` (spike, changed) | `/opt/agents/{package.json,package-lock.json}`, `npm ci --ignore-scripts --prefix /opt/agents`, then only reviewed install scripts whose sha256 matches `agents_allowed_install_scripts`; `/usr/local/bin/{codex,claude}` link to `/opt/agents/node_modules/.bin/…`; `scripts/check-npm-lock.py` checks the lockfile (registry, integrity, install scripts). On hosts, a previous global install under `/opt/agents/{bin,lib}` is left in place (remove it by hand) | same |
| `dotfiles` (new) | refused | Coder dotfiles convention. Inputs: `dotfiles_repo` (validated `https://` or `git@` URL), `dotfiles_ref` (default `main`; README recommends a commit). Clones to `~/.config/ws/dotfiles` as `ws_user`, no become |
| `firewall` (new) | refused | ufw: deny inbound, allow outbound. Rules from `firewall_allow`: a list of `{port, proto: tcp\|udp, from: any\|<cidr>, limit: bool}`. Default `[{port: "{{ ansible_port \| default(22) }}", proto: tcp, from: any, limit: true}]`. If Docker is installed, `DOCKER-USER` rules in `/etc/ufw/after.rules` drop new inbound traffic to container ports from non-local addresses unless listed |
| `hardening` (new) | refused | **Preflight**, which stops the run on failure: `ws_user` has an authorized key; every account with an `authorized_keys` file is in `hardening_ssh_groups` (default `[ws-ssh]`) or listed in `hardening_ssh_lockout_ok`. Creates the groups and adds `ws_user`. **sshd drop-in** `/etc/ssh/sshd_config.d/50-ws.conf`: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowGroups <hardening_ssh_groups>`, `X11Forwarding no`; validated with `sshd -t`. **Reload:** `ssh.service` if active (socket-activated on 24.04; port changes out of scope), then `meta: reset_connection` + `wait_for_connection` proves a fresh login works. **sysctl:** `net.ipv4.conf.all.rp_filter=2` (loose, compatible with Tailscale), `net.ipv4.conf.all.accept_redirects=0`, `net.ipv4.conf.all.send_redirects=0`, `net.ipv6.conf.all.accept_redirects=0`, `kernel.kptr_restrict=2`, `fs.inotify.max_user_watches=524288`, `fs.inotify.max_user_instances=1024` |
| `automation_account` (new, opt-in) | refused | The **only** role that creates a user on a host, and only when listed in a profile or run on its own (`make host PROFILE=bootstrap`). Creates `automation_account_name` (default `openbake`): system shell `/bin/bash`, **locked password** (`password: "!"`), key-only login. Installs one public key per environment from `automation_account_public_key` (inventory `group_vars`, never a private key) into `~/.ssh/authorized_keys` with `copy` (0600; no `ansible.posix` dependency). Sudo drop-in `/etc/sudoers.d/90-openbake`: `Defaults:openbake !requiretty` (needed for SSH pipelining) and `openbake ALL=(root) NOPASSWD: ALL` by default, or password-backed sudo when `automation_account_sudo_nopasswd: false` (become password from the env file / `--ask-become-pass`, never in inventory); validated with `visudo -cf %s`, mode 0440. Adds the account to `hardening_ssh_groups`. After bootstrap, inventories use `ansible_user: openbake`, `ansible_become_method: sudo`, no global `ansible_become` |
| `auto_updates` (new) | refused | `unattended-upgrades`; `/etc/apt/apt.conf.d/20auto-upgrades` with `Update-Package-Lists "1"`, `Unattended-Upgrade "1"`; security origins only; `Automatic-Reboot "false"` |

**Idempotence.** Every spike `changed_when: true` (in agents, code_server, git, neovim, runtimes,
data_sample and postgres) gets a real condition:
- manifest writes use `copy` with content, so they change only when the content changes;
- `npm ci`, `mise install`, extension installs, `uv sync` and lazy restore run only when the
  **sha256 of the wanted version plus its lockfile** differs from the hash recorded in
  `/etc/ws-image/<role>.json`, **or** the installed artifact is missing (this repairs damaged
  installs on hosts).

**Argument specs.** All 13 roles get `meta/argument_specs.yml`. `custom/roles/hello_custom` is an
example and is exempt.

### 6.4 Docker template and runtime contract

**Runtime contract** (every image):
1. `tini -- ws-init <command>`. `ws-init` seeds an empty home from `/etc/skel` once, loads the env
   file (6.5), changes into `~/workspace`, then execs the command.
2. Runs as `user` (uid 1000), home `/home/user`. The `minimal` stage sets `USER user`.
3. The template sets `tty = true` and `stdin_open = true`, so `bash -l` images stay up.
4. No Ansible, package installs or downloads at start.
5. Image-owned editor config, plugins and extensions live outside home (6.3), so image updates
   reach them and home keeps user data.

**Template** (`templates/docker/`). `versions.tf` pins `kreuzwerker/docker`, and `hashicorp/http`
for tests only. `.terraform.lock.hcl` is committed.

| Variable | Default | Meaning |
|---|---|---|
| `profile` | required | `precondition` fails if the profile's `targets` lacks `image` |
| `name` | required (Makefile: `NAME`, default `PROFILE`) | container `ws-<name>`, volume `ws-<name>-home` |
| `image_ref` | required | image reference (labels, output) |
| `image_id` | required (Makefile: `docker image inspect -f {{.Id}}`) | the container uses this ID, so a newly pulled image recreates it on the next `up` |
| `running` | `true` | `false` = container removed, volume kept |
| `env` | `{}` | non-secret variables only. The Makefile refuses keys matching `(?i)(pass\|secret\|token\|key)` and points to the env file |
| `env_file_path` | required | absolute path **on the Docker host** of the env file; bind-mounted read-only at `/run/ws/env` |
| `bind_address` | `127.0.0.1` | `0.0.0.0` only if set explicitly |
| `state_id` | required | UUID of this state directory |
| `profiles_dir` | `${path.module}/../../ansible/profiles` | profiles read with `yamldecode(file(...))`; only `workspace.ports` and `targets` are used |

**Resources:**
- `docker_volume.home`: no `count`, `lifecycle { ignore_changes = all }`.
- `docker_container.ws`: `count = var.running ? 1 : 0`, no `command` (so the image `CMD` runs),
  ports from the profile.
- **Labels** on both: `ws.managed=true`, `ws.name`, `ws.profile`, `ws.state-id`.

**State:**
- OpenTofu uses the local backend:
  `-backend-config=path=.state/<host-id>/<name>/terraform.tfstate`, with
  `TF_DATA_DIR=.state/<host-id>/<name>/.terraform`.
- `.state/<host-id>/ENDPOINT` records the Docker endpoint, and `.state/<host-id>/<name>/ID` holds
  `state_id`.
- `scripts/docker-endpoint.sh` resolves the endpoint: `DOCKER_HOST` if set, otherwise
  `docker context inspect --format '{{.Endpoints.docker.Host}}'` for the active context. Colima,
  OrbStack, Docker Desktop and rootless Docker get separate host IDs.

**Make targets:**

| Target | Behaviour |
|---|---|
| `make up PROFILE= [NAME=] [IMAGE=] [VERIFY=0]` | 1. Image: `IMAGE`, else `ws-<p>:local` if present, else `ghcr.io/rkh0x7ea/openbake/ws-<p>:ubuntu-24.04` (pulled). 2. Verifies the pulled image's signature (6.8) unless `VERIFY=0` or a `:local` image. 3. Ensures the env file (6.5). 4. Conflict check: refuses if a container **or volume** named for this workspace carries a different `ws.state-id`, naming both state directories. 5. `tofu apply -var running=true …` |
| `make stop NAME=` | `tofu apply -var running=false` |
| `make down NAME= [CONFIRM=yes]` | prompts unless `CONFIRM=yes`, then `tofu destroy`; deletes the remote env-file copy |
| `make ls` | containers and volumes with `ws.managed=true` on the current endpoint, plus state directories |
| `make shell NAME=` / `make password NAME=` | `docker exec -it ws-<name> bash -l` / print `PASSWORD` from the env file |

Until T9 publishes images, `make up` works with locally built images (`make image` first).

The template takes no secret inputs. `.state/` is checked for env-file values in tests (6.7).

### 6.5 Secrets

**Rules:**
1. `no_log: true` and `diff: false` on any task that handles a secret.
2. `loop_control.label` excludes secret fields.
3. Never `debug` a registered result that holds secrets.
4. Secret variables are named `vault_*` or `secret_*`. The custom ansible-lint rule
   `ansible/lint/ws_secret_no_log.py` fails tasks that use them without `no_log`.
5. `block`/`rescue` around secret tasks, failing with a message that names the step, never the
   value. There is no "debug secrets" switch.
6. `ansible.cfg`: `display_args_to_stdout = false`, no `log_path`, and
   `[persistent_connection] log_messages = false`. CI fails if `ANSIBLE_LOG_PATH`,
   `ANSIBLE_PERSISTENT_LOG_MESSAGES` or `-vvvv` are set.
7. Temporary files holding secrets are mode 0600 and are removed in an `always:` block.

Secret sources in phase 1 are environment variables and local files only. AWS SSM, keychains,
sops and Kubernetes Secrets come later. The `profile_tasks` callback is not enabled.

**Env file:**
- **Location:** `~/.config/ws/<host-id>/<name>.env`, mode 0600, on the machine running `make`.
- **Creation:** `make up` creates it if missing. For profiles with a `code-server` port it writes
  `PASSWORD=<openssl rand -base64 18>`. Users add API keys.
- **Format:** only lines matching `^[A-Z_][A-Z0-9_]*=.*$`. Other lines are ignored, and values are
  never evaluated by a shell.
- **Local endpoint:** `env_file_path` is the file's absolute path on this machine.
- **Remote `ssh://` endpoint:** `make up` resolves the remote home with
  `ssh <host> 'printf %s "$HOME"'`, runs `mkdir -p -m 700` on
  `<remote_home>/.config/ws/<host-id>/`, and copies the file there with `install -m 600`. It
  passes that remote absolute path as `env_file_path`. `make down` removes the copy.
- **Inside the container:** `ws-init` exports the variables for the main command.
  `/etc/profile.d/ws-env.sh` uses the same parser, so `bash -l` shells (`make shell`) get them.

**Images:** build-time tokens only through `docker buildx --secret`. API keys are never baked in.

**Sentinel test** (`tests/secrets-sentinel.sh`):
- **Fake value:** `WS_SENTINEL_<hex>`, used as:
  - the buildx `github_token` for an `agent` build;
  - `PASSWORD` and `ANTHROPIC_API_KEY` in the env file for `make up PROFILE=devbox`;
  - `secret_sentinel` for `make host PROFILE=workstation` in the host CI job, plus one run forced
    to fail inside a `block`.
- **Search:** all logs, `docker save` output, `.state/` and the runner's temp directory, for the
  value and for `-----BEGIN`.
- **Negative control:** `tests/roles/sentinel_leak` prints the value without `no_log`. The script
  must detect it, otherwise the test fails.

### 6.6 Supply chain and updates

**Pinning:**

| Download | Pin |
|---|---|
| Binaries (mise, code-server, Neovim, OpenTofu, yq, gh, scanners) | version + URL template + sha256 per arch in `versions.yml` |
| apt packages | Ubuntu archive with signed keys |
| npm (agents) | committed `package.json` + `package-lock.json`, `npm ci` |
| Python/Node via mise | committed `mise.lock` |
| uv | `uv-requirements.txt` with hashes, `--require-hashes` |
| LazyVim and plugins | starter commit in `versions.yml`; committed `lazy-lock.json` |
| code-server extensions | version + sha256 in `versions.yml` |
| GitHub SSH host keys | `versions.github_ssh_host_keys` |
| Workspace and runner images | digest pins in `versions.yml` (runner, cosign image) |

**Checks:**
- `scripts/check-pins.py` (CI) fails on any `get_url`/`unarchive` without a `versions.yml`
  checksum, and on extension IDs without an entry.
- **Renovate** runs daily with `minimumReleaseAge: "3 days"` and custom regex managers.
- **Checksums:** `.github/workflows/checksums.yml` runs `scripts/update-checksums.py` on
  `renovate/*` branches:
  - it downloads each changed artifact and computes its sha256;
  - when the entry has `upstream_checksums` (or a signature), the computed value must match it,
    otherwise the job fails;
  - entries without one are labelled `checksum-tofu` on the PR for human review;
  - it commits with a GitHub App token, so CI runs on the new commit.

**Gates:**

| When | Gate |
|---|---|
| PRs that change roles, `versions.yml` or Dockerfiles | **absolute:** fail on any CRITICAL vulnerability with a fix available (Trivy), or any known-malicious package (OSV-Scanner on the SBOM and lock files) |
| Weekly rebuild, Mondays 03:00 UTC | **ratchet** (`security/ratchet.py`): publish if the new image has no blocking finding that the published digest lacks. A finding's identity is (vulnerability ID, package name). The baseline is a fresh Trivy scan of the published digest. With no published digest yet, the absolute gate applies. Old findings that remain get an issue each |
| Every CI run | `security/check-ignores.py` fails on an `ignore.yaml` entry with no reason, or an expiry in the past or more than 30 days out |

**Build and publish (`images.yml`):** covers the four workspace images **and the runner**.
- amd64 and arm64 are built on native runners (`ubuntu-24.04`, `ubuntu-24.04-arm`) and merged with
  `docker buildx imagetools create`.
- Builds use `--sbom=true --provenance=mode=max`.
- The weekly run adds a ClamAV scan of `docker export` output (owner requirement, section 12);
  any hit blocks.
- Images are signed with keyless cosign. Identity:
  `^https://github.com/rkh0x7EA/openbake/.github/workflows/images.yml@refs/`, issuer
  `https://token.actions.githubusercontent.com`.
- Tag scheme in `images/docker-bake.hcl`: `${WS_REGISTRY}/ws-<p>:${WS_TAG}` when `WS_REGISTRY` is
  set, `ws-<p>:${WS_TAG}` when it is empty. Defaults are empty and `local`. CI sets
  `WS_REGISTRY=ghcr.io/rkh0x7ea/openbake` and publishes `ubuntu-24.04` (moving),
  `ubuntu-24.04-<YYYYMMDD>` (fixed) and `edge` (every merge to `main`).

**Nightly re-scan (`rescan.yml`, 02:00 UTC):** Trivy and OSV on each latest published tag. It opens
an issue titled `[rescan] ws-<p> <ID>` unless an open issue with that title already exists.

**Emergency rebuild:** run `images.yml` by hand for one image.

### 6.7 Tests

| Test | Covers | Where |
|---|---|---|
| Lint | ansible-lint (production + `ws_secret_no_log`), yamllint, `tofu fmt -check`, `tofu validate`, gitleaks, `check-pins.py`, `check-ignores.py`, forbidden logging env | `ci.yml` |
| Consistency | 6.2 rules | `ci.yml` |
| Role idempotence | `tests/idempotence.sh <role>` builds the Dockerfile `ansible` stage and mounts the repo. It applies the role's prerequisite chain (from `profiles-consistency.py`) and then the role twice with `ws_target=image`; the second run's recap must show `changed=0`. Image-capable roles only; changed roles come from `git diff --name-only origin/main` | `ci.yml` |
| Target refusals | host-only roles fail with `ws_target=image`; `postgres`/`data_sample` fail with `host`; `make host PROFILE=data` fails; `make up PROFILE=workstation` fails the precondition; `firewall_allow: [{port: "x"}]` fails argument_specs | `ci.yml` |
| Images | `make image` + `make smoke` per changed profile on amd64 and arm64; `make custom FROM=devbox ROLES=hello_custom` + smoke | `ci.yml` |
| Template | `tofu test`:<br>1. `up`; the container runs; port 13337 answers on `127.0.0.1`, not `0.0.0.0`.<br>2. Write a file to home; `stop`; the volume still exists.<br>3. `up` again; the file is still there.<br>4. Change `image_id` (rebuild with a label change); `up`; the container is recreated and the file is still there.<br>5. `.state/` contains no env-file value.<br>6. Conflict: a second state directory for the same name is refused, both with a container and with only a volume left.<br>7. `down`; the volume is gone | `ci.yml` |
| Remote template | `up`/`down` with `DOCKER_HOST=ssh://runner@<runner VM address>` | `host.yml` |
| Host profiles | one fresh job per profile; Docker steps first; `make host` twice (second `changed=0`); checks per the matrix below | `host.yml` |
| Host over SSH | `hardened-server` with `INVENTORY=` pointing at the runner VM over SSH | `host.yml` |
| Runner path | all targets through the runner (default); one job with `NATIVE=1`; `.state/` files owned by the caller; a runner digest that fails verification is refused | `ci.yml`, `host.yml` |
| Secrets sentinel | 6.5 | `ci.yml`, `host.yml` |

**Host check matrix:**

| Check | devbox | agent | workstation | hardened-server |
|---|---|---|---|---|
| second run `changed=0` | ✓ | ✓ | ✓ | ✓ |
| ufw active, only the SSH rule | | | ✓ | ✓ |
| unattended-upgrades enabled | | | ✓ | ✓ |
| root and password logins refused; fresh key login works | | | | ✓ |
| `ws-code-server` on `127.0.0.1` only | ✓ | | | |
| `codex --version`, `claude --version` | | ✓ | ✓ | |

### 6.8 Runner: Docker is the only prerequisite

**Contents.** `ws-runner` is built from `runner/Dockerfile`, with every version pinned in
`versions.yml`:
- Ubuntu 24.04;
- ansible-core 2.21.6, the newest line that runs on Ubuntu 24.04's Python 3.12;
- OpenTofu;
- Docker CLI with buildx;
- Trivy and OSV-Scanner;
- openssh-client.

`make` runs every target in it unless `NATIVE=1`, which uses tools from `bootstrap.sh`.

**Start-up (`runner/ws-runner-init`).** It runs as the caller's uid/gid, plus the Docker socket's
group when the socket is mounted, and:
- writes a passwd/group entry for that uid, which OpenSSH needs;
- sets `HOME=/tmp/ws-home`, which Ansible and OpenTofu use for temp files and caches;
- execs the command.

**Mounts.**
- **Same paths as on the machine:** the repo, `.state/` and `~/.config/ws/` are mounted at their
  host absolute paths, so bind-mount paths handed to the Docker daemon (`env_file_path`) are valid
  on the host.
- **Docker socket:** the unix socket of the resolved Docker endpoint is mounted at
  `/var/run/docker.sock`. On Docker Desktop for Mac this is `/var/run/docker.sock`, which Docker
  Desktop provides. `ssh://` endpoints are passed through as `DOCKER_HOST` instead.
- **SSH agent:** on Linux, `$SSH_AUTH_SOCK`; on Docker Desktop for Mac,
  `/run/host-services/ssh-auth.sock`. `~/.ssh/known_hosts` is mounted read-only.

**Network.**
- On Linux, `--network host`, so `127.0.0.1` inside the runner is the machine itself.
- On Docker Desktop, the default network. Checks against the machine's ports use
  `host.docker.internal`.
- **Local `make host`:** Ansible connects to `ws_user@127.0.0.1` on Linux. (macOS is out of scope
  as a target.)

**Which target mounts what:**

| Target | Repo | `.state/`, `~/.config/ws` | Docker socket | SSH agent |
|---|---|---|---|---|
| `image`, `custom`, `smoke` | ✓ (read-only) | | ✓ | |
| `up`, `stop`, `down`, `ls`, `shell`, `password` | ✓ | ✓ | ✓ (local endpoint) | ✓ (`ssh://` endpoint) |
| `host` | ✓ (read-only) | | | ✓ |

**Trust anchors.** The verifier must not be the runner itself:
- `versions.yml` pins the runner by digest, and also the official cosign image
  (`ghcr.io/sigstore/cosign/cosign@sha256:…`).
- `make` runs that cosign image with `docker run` to verify the runner at first pull and whenever
  its digest changes. It records the verified digest in `.tools/runner-verified`.
- Pulled workspace images are verified the same way (6.4).

The real anchors are the two digest pins in `versions.yml`, reviewed like code.

**Socket risk.** Mounting the socket gives the runner the same control over Docker as the user's
own `docker` commands, which is root-equivalent on Linux. The added risk is trusting the runner
image, which the anchors above cover. `NATIVE=1` avoids the runner entirely.

## 7. Risks and limits

| Risk / limit | Effect | Mitigation |
|---|---|---|
| SSH lockout from `hardening` | operator or other accounts lose access | preflight (key for `ws_user`; every keyed account in `hardening_ssh_groups` or explicitly listed); `sshd -t`; fresh-login check; README: keep a console open on first run |
| ufw doesn't filter Docker-published ports | containers on `0.0.0.0` reachable | `127.0.0.1` default; `DOCKER-USER` rules when Docker is present |
| `.state/` lost | orphaned containers and volumes | labels + `make ls`; conflict check stops a new state taking over an old volume; manual cleanup documented |
| Remote env-file copy | secrets on the remote host while the workspace exists | 0600, removed by `make down`; remote hosts assumed single-user in phase 1 |
| `dotfiles` runs third-party code | arbitrary code as the user | host-only; URL validated; pin `dotfiles_ref` |
| Runner mounts the Docker socket | a compromised runner could control Docker | digest pin, independent cosign verification, `NATIVE=1` |
| Local `make host` needs SSH to the same machine | extra setup on laptops | documented; `NATIVE=1` |
| OpenTofu state management | per-endpoint state, conflict checks, orphan handling: complexity a plain `docker` wrapper wouldn't have | accepted for the later Kubernetes/VM templates (section 8) |
| Version change rebuilds all layers | slower local builds after `versions.yml` edits | accepted (6.2) |
| Read-only LazyVim may not fit lazy.nvim | editor errors | T4 confirms with a spike first; fallback: seed home with a version marker |
| Images allow passwordless sudo by default | full control inside the container | `base_passwordless_sudo: false` in a profile |
| Checksums without an upstream source are trusted on first download | a tampered artifact at first fetch | `checksum-tofu` label forces human review |

## 8. Alternatives considered

| Option | Decision |
|---|---|
| Plain Dockerfiles or devcontainer features instead of Ansible roles | rejected: the same roles must also configure real machines (G4) |
| Nix | rejected for phase 1: host tooling is Ansible |
| `make` + `docker` CLI instead of OpenTofu | rejected: the later Kubernetes and VM templates (section 9) reuse the same OpenTofu shape, following Coder's template model. Cost: state management (section 7) and a larger runner image |
| Real `compose.yaml` | deferred: phase 1 has a single runtime (Docker); Compose matters once a template needs several containers (the data template with a separate Postgres) |
| Three repos (images, templates, provider) | rejected: one clone and no cross-repo version pinning; split when a control plane needs a provider |
| Installing roles into running workspaces | rejected: downloads at start would bypass scanning and signing |
| Native tools as the default user path | rejected: Docker should be the only prerequisite (section 12); native tools remain with `NATIVE=1` |
| Runner configures the local machine through a privileged container (host PID namespace, `nsenter`) | rejected: requires privileged mode and does not work on Docker Desktop's VM |
| Generate the Dockerfile from profiles | deferred: possible with per-role layers, but not needed for 4 images |
| Key-based cosign signing | rejected: keyless needs no key storage or rotation |
| Test Terraform too | deferred: no current user requirement |

## 9. Later (separate small designs)

1. Kubernetes template on k3d (local, decision 2026-11-12). **Remote Kubernetes** follows the
   same split as 6.0: OpenTofu creates cloud resources (VMs, load balancers, DNS); Ansible
   prepares nodes (packages, swap off, kernel modules, sysctl, firewall), installs RKE2 (first
   server initialises, others join via port 9345, join token from the env file), and installs
   cert-manager and Rancher with `kubernetes.core.helm`; Rancher API calls use `uri` with a bearer
   token. Gaps in the reference write-up we must not copy: unguarded `swapoff`, `curl | bash`
   installers (use pinned, checksummed downloads), non-idempotent API POSTs (probe first),
   date-stamped resource names that change every run.
2. Compose.
2a. **Scheduled drift checks:** a nightly job runs `make host … CHECK=1` (`--check --diff`)
    against the `test` inventory and `tofu plan -refresh-only` against workspaces, and opens an
    issue when either reports changes (same dedupe as the nightly re-scan in 6.6).
3. Packer: one AWS AMI from a host profile.
4. Live installs through prebuilt signed role layers or a scanning package mirror.
5. Control plane, UI, accounts and roles (Coder-like): templates with versions and presets,
   image channels, Owner / User Admin / Template Admin / Image Admin / Security Admin / Auditor /
   Member roles.

## 10. Relation to the earlier Ansible dev-env design

This doc replaces the earlier dev-env design for phase 1; its secrets rules are kept in 6.5.

| Dev-env design | Phase 1 |
|---|---|
| in-repo Galaxy collection | plain `ansible/roles/` |
| `ws_context`: image, vm-image, host, live | `ws_target`: image, host |
| `make local` / `make remote` | `make host` (`INVENTORY=` for remote) |
| install/update/configure/verify playbooks; layers as tags | one `apply.yml`; re-running `make host` applies the versions in `versions.yml` |
| Molecule | `tests/idempotence.sh` + host CI jobs |
| `users` role, `users_passwordless_sudo` | `base` creates users only for the `image` target; `base_passwordless_sudo` |
| fail2ban, tailscale, container_engine, cloud_tools, more editors | later |
| Ubuntu, Debian, Fedora, macOS tiers | Ubuntu 24.04 only |

## 11. Review history

The design went through three rounds of review with the Elephant-Goldfish Model (fresh-context
reviewers, severities 🔴/🟡/🟢, one re-audit per stage):

- **Round 1** reviewed the combined platform architecture and led to splitting it into this
  phase-1 design and a later control-plane target.
- **Round 2** reviewed phase 1: 8 blocking and 21 medium findings (host safety of spike roles,
  value precedence, remote env-file path, runner mounts, trust anchors, idempotence prerequisites,
  plan ordering). All were resolved in revision 2.
- **Round 3** (the one allowed re-audit) found remaining gaps: circular cosign verification,
  remote env path, plan total. The author resolved them in revision 3.

The only open technical unknown is the read-only LazyVim layout, which T4 tests first and has a
fallback for.

## 12. Decision log

| Date | Decision | By |
|---|---|---|
| 2026-11-14 | One repo, open source first; control plane later | owner (Roman), in the design session |
| 2026-11-14 | Docker is the only user prerequisite; every tool runs in the runner; `NATIVE=1` opt-out | owner, in the design session |
| 2026-11-14 | A malware (antivirus) scan is part of image checks | owner, in the design session |
| 2026-11-14 | Runner never used to configure the local machine directly; SSH back instead | design, from review round 2 |
| 2026-11-14 | Project name OpenBake; repo `rkh0x7EA/openbake` | owner |
| 2026-11-14 | D4: license Apache-2.0 (explicit patent grant), replacing the MIT file the repo was created with | owner |
| 2026-11-14 | D2: registry GHCR, `ghcr.io/rkh0x7ea/openbake/ws-<profile>` | owner |
| 2026-11-14 | D3: `make up` prefers a `ws-<p>:local` image when one exists | owner |
| 2026-11-14 | Inventories per environment under `ansible/inventories/` (`local`, `test`, `example` committed; real ones git-ignored) | owner |
| 2026-11-14 | Dedicated automation account for host runs (`automation_account` role, opt-in bootstrap); `become` per task or block, not per play | owner |
| 2026-11-15 | Review of PR #6 (EGM + Codex): code-server checksum-pinned; install scripts allowed by content sha256 plus a lockfile check in `make lint`; OSV runs with a fixed `--config` (no adjacent ignore files) and fails on no-packages or malformed reports; images streamed into the scanner (no host temp files); `uv sync --no-build`; uv install marker; npm 11 lockfile with `libc` (no musl builds on glibc); no GitHub token for the neovim step; LazyVim plugins remain unpinned until M4's `lazy-lock.json` (recorded as a gap) | design, from EGM + Codex review |
| 2026-11-15 | Supply-chain hardening ahead of M3/M9: base image by digest; mise/LazyVim pinned; agent CLIs from a committed lockfile (`npm ci --ignore-scripts` + reviewed script allow-list); pip installs hash-pinned, wheels only; OSV-Scanner `MAL-` gate on images and lockfiles; zizmor in `make lint`; policy in `docs/security/supply-chain-policy.md` | owner, from the security research |
| 2026-11-15 | Review of M2 (EGM + Codex): `devbox`/`agent` are image-only until `base` is host-safe (M4) and `make host` exists (M5); host-side T2/6.2 items (`ws_hosts`, `ws_user`/`ws_home` from getent, `WS_VENV`, repo-relative `roles_path`) move to M5; profile vars use set_fact precedence (above inventory/play vars), revisited in M5; the consistency script enforces `-e ws_profile=` on final stages and none on shared stages | design, from EGM + Codex review |
| 2026-11-15 | M2 as built: profile vars are applied with a `set_fact` loop (between role defaults and `-e`); `apply.sh -` runs all roles of `-e ws_profile=`; `make check` re-applies a profile; `jq` stays in `base` (ws-info needs it); devbox has no code-server extensions until M3 pins them | design, from M2 implementation |
| 2026-11-15 | The `os` stage runs `apt-get upgrade`, so a from-scratch build (`make refresh`, weekly) also patches packages inherited from `ubuntu:24.04`; Neovim checksums are keyed by version and unknown versions fail (review of PRs #4/#5) | design, from EGM + Codex review |
| 2026-11-15 | Weekly patching before v0.2: `make refresh` (`--pull --no-cache`, then smoke, check, scan) and a weekly CI run that opens one issue on failure; publishing, signing and nightly rescans stay in v0.2 | owner |
| 2026-11-15 | Roles use probe-then-act: the BuildKit download cache is never state; manifests are written with `copy` content; no `changed_when: true`. `make check` blocks for all images (first part of M4) | design, from CI check-mode results |
| 2026-11-14 | `make ping`: ping + connectivity report (DNS, HTTPS to download sources, IPv4/IPv6) before host runs | owner |
| 2026-11-14 | Tool split (6.0): OpenTofu provisions, Ansible configures; inventories generated from OpenTofu outputs; remote Kubernetes via Ansible-installed RKE2 + Rancher | owner |
| 2026-11-14 | Testing: lint (yamllint, ansible-lint, syntax check, actionlint, shellcheck), `--check` replay on built images, Trivy gate; CI is a thin wrapper over `make ci` | owner |
| 2026-11-14 | D5: copy the spike without history (T1) | owner |
| 2026-11-17 | Broker decision D6 (broker requirements doc, on `feat/sandbox`): M6 is built broker-ready. The Docker template gets an optional internal network and the env file is split into workspace variables and broker-held credentials; the broker stays off by default and broker phase B1 follows M6-M7 | owner |
| 2026-11-17 | M5 `firewall` and `hardening` as built (ansible-core only, so ufw and sysctl are driven with probe-then-act commands and config files, not collection modules). `firewall`: refuses to run when `firewall_allow` has no rule for the SSH port of the run (`firewall_require_ssh_rule`); rules are added, never removed; DOCKER-USER matches published ports by original destination port and treats `firewall_docker_local_cidrs` (loopback and private ranges) as local; IPv4 only. `hardening`: root is exempt from the keyed-account preflight (root login is refused anyway); after writing `50-ws.conf` the role reads `sshd -T` and stops before the reload if another drop-in overrides a setting (sshd keeps the first value, and `50-cloud-init.conf` sorts before `50-ws.conf`); sysctl values live in `/etc/sysctl.d/60-ws.conf`. `make refusals` runs the target-refusal tests in the lint image | implementation |
| 2026-11-19 | M5 `auto_updates`, `dotfiles`, `make ping` and `bootstrap.sh` as built. `auto_updates`: origins are limited in `/etc/apt/apt.conf.d/52ws-unattended-upgrades`, which clears the packaged list first (apt appends to lists). `dotfiles`: does nothing when `dotfiles_repo` is empty; the applied commit is recorded in `~/.config/ws/dotfiles.applied`, so the install script runs again only when the checkout moves; repository metadata files (`.git`, `.github`, `.gitignore`, ...) are never linked. `make ping`: per source and address family, a `getent` lookup and a TCP connection to port 443 of the resolved address (no HTTP request, so no tool is needed on the host and IPv4/IPv6 are tested separately); hosts that only reach the internet through an HTTP proxy report as out of reach. `bootstrap.sh` builds `.tools/venv` with `pip --require-hashes` from `images/requirements/ansible.txt` (no uv; OpenTofu is added with M6). Until the runner lands (M8), host targets need `NATIVE=1`; `.github/workflows/host.yml` starts with the `make ping` job | implementation |

## Detailed Implementation Plan

Each task ends with its check green; checks marked *(manual)* are recorded in the PR.

| # | Task | Files | Check | ad |
|---|---|---|---|---|
| T1 | Move the spike; tag scheme | Copy the spike without history. Move `Dockerfile`, `docker-bake.hcl` → `images/`; `scripts/smoke.sh` → `images/smoke.sh`. Rewrite `README.md` quick start for the new layout. Modify `images/docker-bake.hcl` (`context = "."`, `dockerfile = "images/Dockerfile"`, tag scheme 6.6, defaults `WS_REGISTRY=""`, `WS_TAG=local`), `images/smoke.sh` (`ws-<p>:<tag>` names, profile argument), `Makefile` (`-f images/docker-bake.hcl`; `image PROFILE=`, `smoke PROFILE=`, `custom` → `ws-custom:local`; keep `run-*` until T7). Create `SECURITY.md`, `CONTRIBUTING.md`, `.github/workflows/ci.yml` (build + smoke, amd64 and arm64); extend `.gitignore` | `make image PROFILE=devbox && make smoke PROFILE=devbox` passes on both architectures | 0.5 |
| T2 | Stage graph, image profiles, entry point | Modify `images/Dockerfile`: rename `base` → `minimal`, `USER user`, `cli_tools` RUN, `-e ws_target=image` on every RUN including `custom`, `-e ws_profile` in final stages, remove `EXPOSE`, copy profiles into the `ansible` stage. Create `ansible/roles/cli_tools` (6.3), profiles `minimal`, `devbox`, `data`, `agent`. Modify `ansible/apply.yml`, `ansible/apply.sh`, `ansible/ansible.cfg` (6.2), `images/docker-bake.hcl` (`minimal` target), `images/smoke.sh`, `agents` and `neovim` defaults. Create `scripts/profiles-consistency.py` and add it to `ci.yml` | consistency script passes; all 4 images build and smoke on both architectures | 1.5 |
| T3 | Values and pinning | Create `versions.yml` (6.2 schema), `renovate.json`, `scripts/check-pins.py`, `scripts/update-checksums.py`, `.github/workflows/checksums.yml`, lock files for agents, runtimes, neovim. Modify all roles' defaults to use `versions.*`; `apply.yml` (`include_vars`); Dockerfile `ansible` stage, `ARG WSV_EXTRA_VARS`; `images/docker-bake.hcl`; `git` defaults (`static`) | `check-pins.py` passes; images build and smoke; *(manual)* a test Renovate PR gets a verified checksum commit | 2.5 |
| T4 | Spike roles host-safe and idempotent | Modify `base` (host branch, target assert, `ws-env.sh`), `ws-init` (strict env loading; `cd ~/workspace`), `neovim` (read-only layout, spike first), `code_server` (bind per target, host password file), `agents` (`npm ci`, links), `runtimes`, `data_sample`, `git`, `postgres`: target asserts and real change conditions. Modify `images/smoke.sh`. Create `tests/idempotence.sh` and add it to `ci.yml` | `idempotence.sh` passes for every image-capable role; smoke passes; *(manual)* a home created by the old image sees new plugins after an image update | 2.5 |
| T5 | Host path (native) | Create `bootstrap.sh`, `ansible/inventories/{local,test,example}/`; Makefile `host` with `NATIVE=1`; `.github/workflows/host.yml` jobs for `devbox` and `agent` | `host.yml` jobs pass per the matrix (6.7) | 1 |
| T6 | New host roles and host profiles | Create roles `dotfiles`, `firewall`, `hardening`, `auto_updates` (target asserts, `meta/argument_specs.yml`); argument specs for the other 9 roles; profiles `workstation`, `hardened-server`; `host.yml` jobs for both and the over-SSH job; target-refusal tests in `ci.yml` | `host.yml` matrix passes; refusal tests pass | 2 |
| T7 | Docker template and workspace commands (native) | Create `templates/docker/*`, `scripts/docker-endpoint.sh`; Makefile `up stop down ls shell password` with `NATIVE=1`; remove `run-*`; `tofu test` in `ci.yml`; remote template job in `host.yml` | `tofu test` (all 7 steps) and the remote job pass | 2.5 |
| T8 | Secrets and lint | Modify `ansible/ansible.cfg` (6.5). Create `ansible/lint/ws_secret_no_log.py`, `.ansible-lint`, `.yamllint`, `.gitleaks.toml`, `tests/secrets-sentinel.sh`, `tests/roles/sentinel_leak/`; wire into `ci.yml` and `host.yml` | sentinel passes; negative control detected; lint passes | 1.5 |
| T9 | Supply chain, including the runner image | Create `runner/Dockerfile`, `runner/ws-runner-init`, bake target `runner`; `.github/workflows/images.yml`, `rescan.yml`, `security/*`; runner and cosign digests into `versions.yml` | a deliberately old base with a known fixable CRITICAL fails; the current base passes; `cosign verify` passes on `:edge` for all 5 images; a re-scan creates exactly one issue for a seeded finding | 2.5 |
| T10 | Runner as the default path | Makefile wrapper with the 6.8 mounts, network and uid handling; independent cosign verification of the runner and pulled images; local `make host` over SSH; switch CI jobs to the runner, keep one `NATIVE=1` job | all CI jobs pass through the runner; the `NATIVE=1` job passes; a runner digest that fails verification is refused | 1.5 |
| T11 | Docs and timing | `README.md` (J1-J5), `templates/docker/README.md`, `docs/roles.md`, `docs/security.md`; time G7 | *(manual)* G7 under 10 minutes excluding image downloads, on Ubuntu and a Mac | 1 |
| | **Total** | | | **19.0** |

Order: T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 → T10 → T11. T6 and T7 stay in sequence
because both edit `host.yml` and the Makefile. T9 publishes the runner before T10 makes it the
default.

### Verification plan

1. Every task's check above.
2. **Fresh Ubuntu 24.04 cloud VM**, logged in as `ubuntu`, with Docker installed first:
   `make host PROFILE=hardened-server INVENTORY=…`; `ubuntu` still logs in with its key; root and
   password logins are refused; `ufw status` shows only SSH; a container published on `0.0.0.0`
   is not reachable from outside; a second run reports `changed=0`.
3. **J1 on a Mac with Docker Desktop:** up, password, shell, stop, up (file kept), down. All
   through the runner.
4. **J2** against the VM from step 2.
5. **After a weekly rebuild**, `make up` on an existing workspace: the container is recreated,
   home files are kept, the new plugins are active.

## Open decisions

None. D1-D5 are recorded in the decision log (section 12).
