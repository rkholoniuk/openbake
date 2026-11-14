# Ansible guidelines

Rules for every role in `ansible/roles/` and `custom/roles/`. CI enforces what it can
(`make lint`, `make check`, the secrets sentinel from M7); the rest is review.

## 1. Role shape

- One role installs or configures one thing. Role variables are prefixed with the role name
  (`code_server_port`, not `port`).
- Roles run in two places: inside `docker build` (`ws_target=image`) and on real machines
  (`ws_target=host`). Start every role with an assert on the targets it supports, and never
  create, delete or change users or sudo rules when `ws_target=host`
  ([design 6.3](design/phase1-design.md)).
- Only use facts from the `min` subset (`ansible_facts.architecture`, `distribution`,
  `os_family`, …). Plays gather `min` only. If a role needs more, gather that subset in the role
  with `ansible.builtin.setup: gather_subset: [...]` and say why.
- Use `ansible.builtin.*` modules. Images ship ansible-core only; a collection needs a reason in
  the PR. If a module exists, don't use `command`/`shell` for it (ansible-lint
  `command-instead-of-module`); a `# noqa` needs a comment explaining why.
- Use fully qualified module names and named tasks starting with a capital letter.

### Privilege escalation

- Host runs log in as the dedicated automation account (`openbake`, created by the opt-in
  `automation_account` role), never a personal account. One key per environment, kept in the
  operator's SSH agent or a credential store.
- `become: true` per task or `block`, so reviewers see each privilege boundary. No global
  `ansible_become: true` in inventories; read-only tasks, lookups and asserts stay unprivileged.
- With `NOPASSWD: ALL` any process running as the account can use sudo, so `become` on a task is
  a review boundary, not a security boundary. Restricting sudo to commands doesn't work with
  Ansible (it runs temporary module files); prefer moving changes into image builds.
- Sudoers files are written with `validate: visudo -cf %s` and mode `"0440"`; automation accounts
  have `!requiretty` (pipelining needs it).
- Become passwords: `--ask-become-pass` (`make host` uses `-K`) or the env file; never in
  inventories, never as a command-line argument.
- Rotate the automation key when people leave and when an environment is retired.

## 2. Idempotence and check mode

- A second run reports `changed=0`. `changed_when` must describe a real change. Never write
  `changed_when: true`.
- Every role works with `--check --diff`. `make check` re-applies each image's roles in check
  mode and fails unless the recap shows `changed=0`.
  - Read-only probes whose result later tasks need (`uri` GET, `command` that only reads, `stat`)
    get `check_mode: false`, otherwise they are skipped and the next task breaks.
  - `command`/`shell` tasks that change things are skipped in check mode; guard them with
    `creates:`/`removes:` or a probe, so check mode can still predict the change.
- Downloads use `get_url`/`unarchive` with a `checksum:` from `versions.yml` (enforced by
  `scripts/check-pins.py` from M3). No moving versions (`latest`, `stable`, `main`) in defaults.
- apt tasks may use `cache_valid_time`; `apply.yml` refreshes empty package lists first (BuildKit
  cache mounts start empty on a fresh builder).

## 3. Secrets

Vault and env files protect secrets *at rest* only. Once a value is decrypted or loaded, the role
author is responsible for keeping it out of output, logs, diffs, caches and images.

### In tasks

1. `no_log: true` on the task that **reads** a secret (lookup, `slurp`, `uri` that returns a
   token) **and** on every later task that **uses** it. `no_log` only protects its own task.
2. Loops over secret data get `no_log: true` on the whole task. `loop_control.label` is not
   enough: failure output still contains the full item.
3. `diff: false` on any task that renders a file containing a secret. Set it in the role, so
   `--diff` from a caller can't expose it. Assume `--check --diff` runs in CI.
4. Never `debug` a variable or registered result that holds a secret. Treat registered results
   as sensitive (they can hold request bodies and headers); register only what you need.
5. `assert` on secret values: `no_log: true`, `quiet: true`, and a generic `fail_msg`.
6. `block`/`rescue` around secret tasks; the failure message names the step, never the value.
   There is no "debug secrets" switch, and `no_log` is never removed to debug in shared CI.
7. Secrets never appear in task names, item labels, tags, handler names, host aliases or
   inventory variables that get cached.
8. Name secret variables `secret_*` or `vault_*`. The ansible-lint rule `ws_secret_no_log` (M7)
   fails any task that uses them without `no_log`.

### Commands, URLs, files

9. Prefer modules with protected parameters over `command`/`shell` with a password on the
   command line (process lists and logs see it).
10. Tokens go in an `Authorization` header, never in a URL query string.
11. Files with secrets: explicit `owner`, `group` and `mode` (`"0600"` or `"0640"`). Temporary
    files are `0600` and removed in an `always:` block.
12. `set_fact` with a secret never uses `cacheable: true`.

### Controller and CI

13. `ansible/ansible.cfg` keeps `display_args_to_stdout = false`, has no `log_path`, uses the
    in-memory fact cache, and sets `[persistent_connection] log_messages = false`.
14. Never enable `ANSIBLE_DEBUG`, and don't use `-vvvv` in CI: debug output can include secrets
    even with `no_log`. CI fails if `ANSIBLE_LOG_PATH`, `ANSIBLE_DEBUG` or
    `ANSIBLE_PERSISTENT_LOG_MESSAGES` is set (M7).
15. Don't add callback plugins without checking that they honour `no_log` censoring.

### Images

16. Build-time tokens only through `docker buildx --secret` (mounted at `/run/secrets/<id>`,
    never in a layer). API keys are never baked into an image; they come from the workspace env
    file at start.
17. `make scan` (Trivy) also scans image layers for secrets.

### Testing for leaks

18. The sentinel test (M7) uses a unique fake secret and searches all output for it: success,
    module failure, failure inside `block`, loops, `--check --diff`, build logs, image layers
    (`docker save`), and OpenTofu state. A negative control that deliberately prints the value
    must be detected, otherwise the test itself is broken.

## 4. Performance

- Plays use `gather_subset: [min]`; don't add `gather_facts: true` elsewhere.
- No persistent fact cache (stale facts across build steps and changed hosts cost more than the
  ~1 s per play it would save).
- SSH pipelining is on for `make host`.
- In images, each role is its own `RUN` layer: put rarely changing roles first, and keep
  downloads in the BuildKit cache mounts (`/var/cache/ws`, apt, npm, pip, uv).

## 5. Before opening a PR

```sh
make lint                              # yamllint, syntax check, ansible-lint, actionlint, shellcheck
make ci PROFILE=minimal                # fast loop; `make ci` runs everything CI runs
```

Sources: [design 6.5](design/phase1-design.md);
[Preventing Ansible secret leaks](https://oneuptime.com/blog/post/2026-07-24-preventing-ansible-secret-leaks/view);
[Speeding up Ansible facts](https://oneuptime.com/blog/post/2026-07-24-speeding-up-ansible-facts/view).
