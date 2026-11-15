#!/usr/bin/env python3
"""Check ansible/profiles/*.yml against images/Dockerfile and ansible/roles/.

Rules (ansible/profiles/README.md):
  - name matches the file name; targets are a subset of {image, host}
  - roles is a one-line flow list, and every role exists in ansible/roles/
  - an image profile has a Dockerfile stage of the same name whose role chain
    (apply.sh calls along its FROM chain) equals the profile's roles, in order
  - image profiles set vars only for roles in their own final stage (shared
    stages take role defaults only); every var is defined in some role's defaults
  - workspace ports are integers; the Dockerfile has no EXPOSE

Usage: scripts/profiles-consistency.py [--chains]
  --chains  also print, for each role, the role chain before it (its prerequisites)
Exit status 1 on any violation.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCKERFILE = ROOT / "images" / "Dockerfile"
PROFILES = ROOT / "ansible" / "profiles"
ROLES = ROOT / "ansible" / "roles"

FROM_RE = re.compile(r"^FROM\s+(\S+)\s+AS\s+(\S+)", re.IGNORECASE)
APPLY_RE = re.compile(r"/opt/ansible/apply\.sh\s+(\S+)")


def parse_dockerfile(text):
    """Return ({stage: parent}, {stage: [own roles]}, has_expose)."""
    parents, own, stage = {}, {}, None
    has_expose = False
    # Join continuation lines so a RUN spanning several lines is one instruction.
    for line in text.replace("\\\n", " ").splitlines():
        line = line.strip()
        m = FROM_RE.match(line)
        if m:
            stage = m.group(2)
            parents[stage] = m.group(1)
            own[stage] = []
            continue
        if re.match(r"^EXPOSE\b", line, re.IGNORECASE):
            has_expose = True
        if stage and line.upper().startswith("RUN"):
            for arg in APPLY_RE.findall(line):
                if arg.startswith("$") or arg.startswith('"$') or arg == "-":
                    continue  # custom stage (${CUSTOM_ROLES}) or profile-driven
                own[stage].extend(r.strip() for r in arg.split(",") if r.strip())
    return parents, own, has_expose


def chain(stage, parents, own):
    roles, seen = [], set()
    while stage in own and stage not in seen:
        seen.add(stage)
        roles = own[stage] + roles
        stage = parents.get(stage)
    return roles


def role_defaults():
    owner = {}
    for path in sorted(ROLES.glob("*/defaults/main.yml")):
        data = yaml.safe_load(path.read_text()) or {}
        for key in data:
            owner.setdefault(key, path.parent.parent.name)
    return owner


def main():
    errors = []
    parents, own, has_expose = parse_dockerfile(DOCKERFILE.read_text())
    if has_expose:
        errors.append("images/Dockerfile: EXPOSE found; ports belong in profiles (workspace.ports)")
    owners = role_defaults()
    existing_roles = {p.name for p in ROLES.iterdir() if p.is_dir()}

    profiles = sorted(PROFILES.glob("*.yml"))
    if not profiles:
        errors.append("no profiles found in ansible/profiles/")
    for path in profiles:
        rel = path.relative_to(ROOT)
        text = path.read_text()
        data = yaml.safe_load(text) or {}
        name = data.get("name")
        if name != path.stem:
            errors.append(f"{rel}: name {name!r} must match the file name {path.stem!r}")
        targets = data.get("targets") or []
        if not targets or not set(targets) <= {"image", "host"}:
            errors.append(f"{rel}: targets must be a non-empty subset of [image, host], got {targets}")
        if not re.search(r"^roles: *\[[^\]\n]*\] *$", text, re.MULTILINE):
            errors.append(f"{rel}: roles must be a one-line flow list, e.g. roles: [base, git]")
        roles = data.get("roles") or []
        for role in roles:
            if role not in existing_roles:
                errors.append(f"{rel}: role {role!r} does not exist in ansible/roles/")
        ports = ((data.get("workspace") or {}).get("ports")) or {}
        for label, port in ports.items():
            if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
                errors.append(f"{rel}: port {label}={port!r} must be an integer 1-65535")
        profile_vars = data.get("vars") or {}
        for key in profile_vars:
            if key not in owners:
                errors.append(f"{rel}: var {key!r} is not defined in any role's defaults/main.yml")
            elif owners[key] not in roles:
                errors.append(f"{rel}: var {key!r} belongs to role {owners[key]!r}, which the profile doesn't use")

        if "image" in targets:
            if name not in own:
                errors.append(f"{rel}: image profile has no Dockerfile stage named {name!r}")
                continue
            built = chain(name, parents, own)
            if built != roles:
                errors.append(f"{rel}: roles {roles} differ from the Dockerfile chain of stage {name!r}: {built}")
            final_stage = set(own[name])
            for key in profile_vars:
                if key in owners and owners[key] in roles and owners[key] not in final_stage:
                    errors.append(
                        f"{rel}: var {key!r} is for role {owners[key]!r} in a shared stage; "
                        f"image profiles may set vars only for {sorted(final_stage)}"
                    )

    if "--chains" in sys.argv[1:]:
        printed = set()
        for stage in own:
            built = chain(stage, parents, own)
            for i, role in enumerate(built):
                if role not in printed:
                    printed.add(role)
                    print(f"{role}: {','.join(built[:i]) or '-'}")

    for err in errors:
        print(f"profiles-consistency: {err}", file=sys.stderr)
    if not errors:
        print(f"profiles-consistency: {len(profiles)} profiles OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
