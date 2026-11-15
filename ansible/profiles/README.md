# Profiles

A profile is the single name for an image, a host setup and (from M6) a workspace.

```yaml
name: devbox                 # must match the file name
targets: [image, host]       # where it may be applied (apply.yml refuses others)
roles: [base, git, cli_tools, runtimes, neovim, code_server]   # in layer order, one line
vars:                        # role variables; override role defaults, -e still wins
  code_server_extensions: [ms-python.python]
workspace:
  ports: { code-server: 13337 }   # ports the workspace publishes (no EXPOSE in the Dockerfile)
```

Rules, checked by `scripts/profiles-consistency.py` in `make lint`:

- For an `image` profile, `roles` equals the role chain of its Dockerfile stage, in order.
- Every role exists in `ansible/roles/`.
- Image profiles set `vars` only for roles in their own final stage. Shared stages
  (`minimal`, `runtimes`) take values from role defaults only, because several images reuse
  their layers.
- `roles` is a one-line flow list, ports are integers, and the Dockerfile has no `EXPOSE`.
