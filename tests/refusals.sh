#!/bin/sh
# Target refusals (design 6.7): each case must FAIL, and for the expected reason.
# A case that passes, or fails with a different message, fails this script.
#   tests/refusals.sh
# Runs in the lint image (`make refusals`). Every run uses --check, so a role
# that wrongly accepts its input still changes nothing.
set -eu
cd "$(dirname "$0")/.."

failed=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# refuse <description> <expected message (grep -E)> <ansible-playbook args...>
refuse() {
  desc="$1"
  want="$2"
  shift 2
  if ansible-playbook -i localhost, tests/refusals.yml --check "$@" >"$log" 2>&1; then
    echo "FAIL  $desc: the run succeeded, it must be refused" >&2
    failed=1
  elif ! grep -Eq "$want" "$log"; then
    echo "FAIL  $desc: refused, but not with /$want/:" >&2
    tail -15 "$log" >&2
    failed=1
  else
    echo "ok    $desc"
  fi
}

# Host-only roles in an image build.
for role in firewall hardening; do
  refuse "$role with ws_target=image" "$role does not support ws_target=image" \
    -e "ws_role=$role" -e ws_target=image
done

# Bad arguments stop at argument_specs, before the role's first task.
refuse "firewall_allow with a non-numeric port" "unable to convert to int" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": "x"}]}'
refuse "firewall_allow with an unknown protocol" "value of proto must be one of" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": 22, "proto": "icmp"}]}'

# The lockout guards.
refuse "firewall_allow without the SSH port" "no rule for SSH port" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": 443}]}'
refuse "firewall rule with a bad source" "must be any, an address or a CIDR" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": 22, "from": "office"}]}'
refuse "hardening with no SSH group" "hardening_ssh_groups is empty" \
  -e ws_role=hardening -e ws_target=host -e '{"hardening_ssh_groups": []}'

exit "$failed"
