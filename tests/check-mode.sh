#!/bin/sh
# Re-apply roles in check mode and fail unless the recap shows changed=0.
#   tests/check-mode.sh <role>[,<role>...]
# Runs inside the `check` build stage (images/Dockerfile); see `make check`.
set -eu
roles="$1"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

set +e
/opt/ansible/apply.sh "$roles" -e ws_target=image --check --diff >"$log" 2>&1
rc=$?
set -e
cat "$log"

if [ "$rc" -ne 0 ]; then
  echo "check mode: ansible-playbook failed (exit $rc) for: $roles" >&2
  exit "$rc"
fi
recap="$(grep -E '^localhost +:' "$log" | tail -1)"
case "$recap" in
  *" changed=0 "*) echo "check mode: no changes for: $roles" ;;
  *)
    echo "check mode: changes reported for: $roles" >&2
    grep -E '^(changed|TASK) ' "$log" | grep -B1 '^changed' | grep '^TASK' >&2 || true
    exit 1 ;;
esac
