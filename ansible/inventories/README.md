# Inventories

One directory per environment, used by `make host INVENTORY=ansible/inventories/<env>` (M5).

| Directory | Committed | Use |
|---|---|---|
| `local/` | yes | this machine (`make host PROFILE=workstation`) |
| `test/` | yes | disposable machines for host-target tests (CI runner VMs, throwaway cloud VMs) |
| `example/` | yes | template: copy to `staging/`, `production/` or any name |
| anything else | **no** (`.gitignore`) | your real environments, e.g. `production/` |

Real inventories (hostnames, addresses, users) belong to whoever runs OpenBake and are never
committed here. Keep secrets out of inventories entirely: use env files or Ansible Vault with
`secret_*`/`vault_*` names (see `docs/ansible-guidelines.md`).

Variable precedence for a host run (lowest first): role defaults → `versions.yml` → profile
`vars` → inventory `group_vars/` → `host_vars/` → `VARS='<json>'` on the command line.
