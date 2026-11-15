#!/bin/sh
# Apply one or more roles to this machine.
#
#   apply.sh base,git            # roles, comma-separated
#   apply.sh runtimes -e '{"node_versions": ["24"]}'
#
# Runs inside `docker build` (Ansible is bind-mounted, never baked in) and also
# works in a live workspace or on a VM with the same roles.
#
# Variables: every environment variable named WSV_<NAME> becomes the Ansible
# extra var <name> (lower-cased). Values that parse as JSON are passed as JSON,
# anything else as a string, so build args like
#   WSV_PYTHON_VERSIONS='["3.13","3.12"]'
# override role defaults. Empty values are ignored.
set -eu

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: apply.sh <role>[,<role>...] [ansible-playbook args]" >&2
  exit 2
fi
roles="$1"
shift

here="$(dirname "$0")"
vars_file="$(mktemp)"
trap 'rm -f "$vars_file"' EXIT

"$here/venv/bin/python" - "$vars_file" <<'EOF'
import json, os, sys
out = {}
for key, value in os.environ.items():
    if not key.startswith("WSV_") or value == "":
        continue
    try:
        out[key[4:].lower()] = json.loads(value)
    except ValueError:
        out[key[4:].lower()] = value
with open(sys.argv[1], "w") as fh:
    json.dump(out, fh)
EOF

# Build secret (docker buildx --secret id=github_token): raises GitHub's API
# rate limit for tools that resolve versions there (mise). Never written to a layer.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -s /run/secrets/github_token ]; then
  GITHUB_TOKEN="$(cat /run/secrets/github_token)"
  export GITHUB_TOKEN
fi

export ANSIBLE_CONFIG="$here/ansible.cfg"
exec "$here/venv/bin/ansible-playbook" "$here/apply.yml" \
  -e "ws_roles=$roles" -e "@$vars_file" "$@"
