#!/bin/sh
# Tools for NATIVE=1 (running make targets without the runner container):
# ansible-core in .tools/venv, at the same pinned, hash-checked versions the
# images use (images/requirements/ansible.txt).
#   ./bootstrap.sh
# Needs python3 >= 3.12 with the venv module. Nothing is installed outside .tools/.
set -eu
cd "$(dirname "$0")"

if ! python3 -c 'import sys, venv; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
  echo "bootstrap.sh: needs python3 >= 3.12 with the venv module (Ubuntu: apt install python3-venv)" >&2
  exit 1
fi

python3 -m venv .tools/venv
.tools/venv/bin/pip install --quiet --disable-pip-version-check --require-hashes \
  -r images/requirements/ansible.txt
.tools/venv/bin/ansible-playbook --version | head -1
echo "bootstrap.sh: ready, use NATIVE=1 (e.g. make ping NATIVE=1)"
