# Profiles

A profile is the single name for an image, a host setup and (from M6) a workspace.

```yaml
name: devbox                 # must match the file name
targets: [image]             # where it may be applied (apply.yml refuses others); host from M5
roles: [base, git, cli_tools, runtimes, neovim, code_server]   # in layer order, one line
vars:                        # role variables (see precedence below)
  code_server_port: 13337
workspace:
  ports: { code-server: 13337 }   # ports the workspace publishes (no EXPOSE in the Dockerfile)
```

Variable precedence: profile `vars` override role defaults, role `vars/`, play vars and inventory
vars; only `-e` extra vars win. In images they apply to the roles of the profile's own final
stage only.

Rules, checked by `scripts/profiles-consistency.py` in `make lint`:

- For an `image` profile, `roles` equals the role chain of its Dockerfile stage, in order.
- Every role exists in `ansible/roles/`.
- Image profiles set `vars` only for roles their final stage applies with
  `-e ws_profile=<name>`. Shared stages (`minimal`, `runtimes`) must not pass a profile and take
  role defaults only, because several images reuse their layers. So `minimal` takes no vars.
- Only real `apply.sh` commands count as role runs (not `echo`, `chmod` or comments).
- `roles` is a one-line flow list, ports are integers, and the Dockerfile has no `EXPOSE`.
