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
for role in firewall hardening auto_updates dotfiles; do
  refuse "$role with ws_target=image" "$role does not support ws_target=image" \
    -e "ws_role=$role" -e ws_target=image
done

# Bad arguments stop at argument_specs, before the role's first task.
refuse "firewall_allow with a non-numeric port" "unable to convert to int" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": "x"}]}'
refuse "firewall_allow with an unknown protocol" "value of proto must be one of" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": 22, "proto": "icmp"}]}'

refuse "firewall_docker_interfaces with iptables syntax" "firewall_docker_interfaces takes interface names" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_docker_interfaces": ["docker0 -j ACCEPT"]}'
refuse "firewall_docker_local_cidrs with a hostname" "firewall_docker_interfaces takes interface names" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_docker_local_cidrs": ["0.0.0.0/0 -j ACCEPT"]}'

# The lockout guards.
refuse "firewall_allow without the SSH port" "no rule for SSH port" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": 443}]}'
refuse "firewall rule with a bad source" "must be any, an address or a CIDR" \
  -e ws_role=firewall -e ws_target=host -e '{"firewall_allow": [{"port": 22, "from": "office"}]}'
refuse "hardening with no SSH group" "hardening_ssh_groups is empty" \
  -e ws_role=hardening -e ws_target=host -e '{"hardening_ssh_groups": []}'

refuse "auto_updates with no origins" "auto_updates_origins is empty" \
  -e ws_role=auto_updates -e ws_target=host -e '{"auto_updates_origins": []}'
# Local paths and git remote helpers (ext::, file://) must never be cloned.
for repo in /etc "ext::sh -c id" file:///etc -oProxyCommand=id https://me:token@example.com/me/dotfiles; do
  refuse "dotfiles_repo=$repo" "dotfiles_repo must be an https://host/path" \
    -e ws_role=dotfiles -e ws_target=host -e "{\"dotfiles_repo\": \"$repo\"}"
done
refuse "dotfiles_ref starting with a dash" "dotfiles_repo must be an https://host/path" \
  -e ws_role=dotfiles -e ws_target=host -e '{"dotfiles_repo": "https://example.com/me/dotfiles", "dotfiles_ref": "--upload-pack=id"}'

exit "$failed"
