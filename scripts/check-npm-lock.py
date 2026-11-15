#!/usr/bin/env python3
"""Check the agent CLIs' npm lockfile (run by make lint).

  - every package comes from https://registry.npmjs.org/ (no git, URL or file sources)
  - every package has an sha512 integrity hash
  - every package with an install script is listed, by package name, in
    agents_allowed_install_scripts (ansible/roles/agents/defaults/main.yml);
    its content hash is checked at install time by the role
  - the lockfile was written by npm >= 7 (lockfileVersion 3)

Exit status 1 on any violation.
"""
import base64
import binascii
import json
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROLE = ROOT / "ansible" / "roles" / "agents"
REGISTRY = "https://registry.npmjs.org/"


def valid_sha512(integrity):
    """True for exactly one 'sha512-<base64 of 64 bytes>' entry."""
    if not isinstance(integrity, str) or not integrity.startswith("sha512-") or " " in integrity.strip():
        return False
    try:
        return len(base64.b64decode(integrity[len("sha512-"):], validate=True)) == 64
    except (ValueError, binascii.Error):
        return False


def main():
    errors = []
    lock_path = ROLE / "files" / "package-lock.json"
    lock = json.loads(lock_path.read_text())
    defaults = yaml.safe_load((ROLE / "defaults" / "main.yml").read_text()) or {}
    allowed = {entry["package"] for entry in defaults.get("agents_allowed_install_scripts") or []}

    if lock.get("lockfileVersion") != 3:
        errors.append(f"lockfileVersion is {lock.get('lockfileVersion')}, expected 3")
    packages = lock.get("packages") or {}
    for key, entry in packages.items():
        if not key:
            continue  # the root project
        name = key.split("node_modules/")[-1]
        resolved = entry.get("resolved", "")
        if not resolved.startswith(REGISTRY):
            errors.append(f"{name}: resolved from {resolved or 'nowhere'}, not {REGISTRY}")
        if not valid_sha512(entry.get("integrity")):
            errors.append(f"{name}: no valid sha512 integrity hash")
        if entry.get("hasInstallScript") and name not in allowed:
            errors.append(
                f"{name}: has an install script that is not reviewed "
                "(add it to agents_allowed_install_scripts with its sha256, or drop the package)"
            )
    for name in sorted(allowed):
        if f"node_modules/{name}" not in packages:
            errors.append(f"agents_allowed_install_scripts lists {name}, which the lockfile doesn't contain")

    for err in errors:
        print(f"check-npm-lock: {err}", file=sys.stderr)
    if not errors:
        print(f"check-npm-lock: {len(packages) - 1} packages OK (registry, integrity, install scripts)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
