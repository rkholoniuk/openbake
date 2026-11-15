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
import shlex
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCKERFILE = ROOT / "images" / "Dockerfile"
PROFILES = ROOT / "ansible" / "profiles"
ROLES = ROOT / "ansible" / "roles"

FROM_RE = re.compile(r"^FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?\s*$", re.IGNORECASE)
APPLY = "/opt/ansible/apply.sh"


def parse_run(cmd, where, errors):
    """Return [(roles, profile)] for the apply.sh calls in one RUN instruction.

    Only a command segment that starts with apply.sh (after --mount flags and
    VAR=value assignments) counts. Other mentions (chmod, echo) are ignored, so
    text in an echo can't pass for a role run; whole-line comments are dropped.
    """
    calls = []
    for segment in re.split(r";|&&|\|\|", cmd):
        if "apply.sh" not in segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            errors.append(f"{where}: cannot parse RUN segment: {segment.strip()[:80]}")
            continue
        while tokens and (tokens[0].startswith("--") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0])):
            tokens.pop(0)
        if not tokens or tokens[0] != APPLY or len(tokens) < 2:
            continue  # apply.sh mentioned but not run (chmod, echo, ...): not a role run
        profile = None
        for i, tok in enumerate(tokens[2:], start=2):
            if tok == "-e" and i + 1 < len(tokens) and tokens[i + 1].startswith("ws_profile="):
                profile = tokens[i + 1].split("=", 1)[1]
        calls.append((tokens[1], profile))
    return calls


def parse_dockerfile(text, errors):
    """Return ({stage: parent}, {stage: [(role, profile)]}, has_expose)."""
    parents, own, stage, anon = {}, {}, None, 0
    has_expose = False
    # Docker drops whole-line comments, also inside a continued RUN.
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    for line in "\n".join(lines).replace("\\\n", " ").splitlines():
        line = line.strip()
        if line.upper().startswith("FROM "):
            m = FROM_RE.match(line)
            if not m:
                errors.append(f"images/Dockerfile: cannot parse: {line}")
                continue
            if m.group(2):
                stage = m.group(2)
            else:
                anon += 1
                stage = f"<unnamed {anon}>"
            parents[stage] = m.group(1)
            own[stage] = []
            continue
        if re.match(r"^EXPOSE\b", line, re.IGNORECASE):
            has_expose = True
        if stage and re.match(r"^RUN\b", line, re.IGNORECASE):
            for roles, profile in parse_run(line[3:], f"images/Dockerfile stage {stage}", errors):
                if roles.startswith("$") or roles == "-":
                    continue  # custom stage (${CUSTOM_ROLES}) or profile-driven
                for role in (r.strip() for r in roles.split(",")):
                    if role:
                        own[stage].append((role, profile))
    return parents, own, has_expose


def chain(stage, parents, own):
    roles, seen = [], set()
    while stage in own and stage not in seen:
        seen.add(stage)
        roles = [r for r, _ in own[stage]] + roles
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
    parents, own, has_expose = parse_dockerfile(DOCKERFILE.read_text(), errors)
    # A stage is shared when another named stage builds FROM it; shared stages
    # must not apply a profile (their layers are reused by several images).
    shared = {p for p in parents.values() if p in own}
    for stage, calls in own.items():
        for role, profile in calls:
            if stage in shared and profile:
                errors.append(f"images/Dockerfile stage {stage}: shared stage must not pass -e ws_profile ({role})")
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
        try:
            data = yaml.safe_load(text) or {}
        except yaml.YAMLError as exc:
            errors.append(f"{rel}: invalid YAML: {exc}")
            continue
        if not isinstance(data, dict):
            errors.append(f"{rel}: must be a mapping")
            continue
        name = data.get("name")
        if name != path.stem:
            errors.append(f"{rel}: name {name!r} must match the file name {path.stem!r}")
        targets = data.get("targets") or []
        if not targets or not set(targets) <= {"image", "host"}:
            errors.append(f"{rel}: targets must be a non-empty subset of [image, host], got {targets}")
        if not re.search(r"^roles: *\[[^\]\n]*\] *(#.*)?$", text, re.MULTILINE):
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
            # Roles that get this profile's vars at build time: the stage's own
            # apply.sh calls with -e ws_profile=<name> (none if the stage is shared).
            with_profile = set()
            for role, profile in own[name]:
                if name in shared:
                    continue
                if profile != name:
                    errors.append(
                        f"images/Dockerfile stage {name}: role {role} must be applied with "
                        f"-e ws_profile={name} (got {profile or 'none'})"
                    )
                else:
                    with_profile.add(role)
            for key in profile_vars:
                if key in owners and owners[key] in roles and owners[key] not in with_profile:
                    errors.append(
                        f"{rel}: var {key!r} is for role {owners[key]!r}, which the build doesn't apply "
                        f"with this profile; allowed: {sorted(with_profile) or 'none (shared stage)'}"
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
