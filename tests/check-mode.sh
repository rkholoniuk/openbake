#!/bin/sh
# Re-apply a profile's roles in check mode and fail unless the recap shows changed=0.
#   tests/check-mode.sh <profile>
# Runs inside the `check` build stage (images/Dockerfile); see `make check`.
set -eu
profile="$1"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

set +e
/opt/ansible/apply.sh - -e ws_target=image -e "ws_profile=$profile" --check --diff >"$log" 2>&1
rc=$?
set -e
cat "$log"

if [ "$rc" -ne 0 ]; then
  echo "check mode: ansible-playbook failed (exit $rc) for profile $profile" >&2
  exit "$rc"
fi
recap="$(grep -E '^localhost +:' "$log" | tail -1)"
case "$recap" in
  *" changed=0 "*) echo "check mode: no changes for profile $profile" ;;
  *)
    echo "check mode: changes reported for profile $profile" >&2
    grep -E '^(changed|TASK) ' "$log" | grep -B1 '^changed' | grep '^TASK' >&2 || true
    exit 1 ;;
esac
