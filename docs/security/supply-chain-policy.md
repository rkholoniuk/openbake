# Supply-chain policy

How OpenBake chooses, pins, checks and replaces what goes into its images. Status as of
2026-11-15. Each rule says how it is enforced: **CI** (a gate fails), **build** (the build fails),
or **review** (maintainers check it in pull requests). Items marked *(M3)*, *(M4)*, *(M9)* or
*(v0.2)* are planned. Section 10 lists the known gaps.
Framework reference: OpenSSF S2C2F (secure consumption) and SLSA (build integrity); the target is
S2C2F level 2 plus the cheap level 3 controls (malicious-package deny list, malware scan) by v0.2.
Background and sources: the research note that led to this policy (2026-11-15).

## 1. Scope

OpenBake ships workspace images (`ws-minimal`, `ws-devbox`, `ws-data`, `ws-agent`), the Ansible
roles that build them, and later a runner image. Report vulnerabilities as described in
[SECURITY.md](../../SECURITY.md).

OpenBake is a non-commercial open-source project. Under the EU Cyber Resilience Act it is likely
out of scope today; companies that ship OpenBake in their products are manufacturers and will want
SBOMs, this policy and a vulnerability process, which is why we keep them.

## 2. Sources we consume

| Source | Used for | Pinned by |
|---|---|---|
| Docker Hub `ubuntu:24.04` | base image | multi-arch index digest in `images/Dockerfile` |
| Ubuntu archive (signed) | apt packages | archive signatures; `apt-get upgrade` on every from-scratch build |
| GitHub releases | mise, Neovim, code-server, yq, gh, Trivy, OSV-Scanner, actionlint | version + sha256 per architecture, checked against the release's checksum file or GitHub's asset digest; a version without a pinned checksum fails (**build**) |
| npmjs.org | Codex and Claude Code CLIs and their dependencies | `ansible/roles/agents/files/package-lock.json` (registry, integrity and install scripts checked by `scripts/check-npm-lock.py`, **CI**), `npm ci --ignore-scripts` |
| PyPI | ansible-core, lint tools, uv; data sample deps | version + sha256 (`--require-hashes --only-binary :all:`); `uv.lock` (`uv sync --frozen --no-build`) |
| mise (python-build-standalone, nodejs.org) | Python and Node | major/minor versions in role defaults, resolved at build time; `mise.lock` *(M3)* (gap, section 10) |
| GitHub (git) | LazyVim starter; its plugins | starter: commit SHA; plugins: not yet pinned, `lazy-lock.json` *(M4)* (gap, section 10) |
| Open VSX | code-server extensions | none installed until pinned *(M3)* |
| GitHub Actions | CI | full commit SHA, version in a comment (`make lint` rejects anything else) |

A new source needs a PR that adds it to this table.

## 3. Rules

1. **Pin everything** (**build**, **CI**, gaps in section 10). Digests for images, sha256 for
   downloads, lockfiles with hashes for npm and PyPI, commit SHAs for git and Actions. No
   `latest`, `stable` or `main`. A version without a pinned checksum fails the build instead of
   downloading unchecked (mise, Neovim, code-server); Actions not pinned by SHA fail `make lint`.
2. **No unreviewed install scripts at build time** (**build**, **CI**). npm runs with
   `--ignore-scripts`. A script runs only if it is listed in `agents_allowed_install_scripts` and
   its content matches the recorded sha256 (today: Claude Code's `install.cjs`, which copies its
   native binary out of the platform package the lockfile installed). `make lint` fails on any
   locked package with an install script that isn't listed.
3. **No package builds at install time** (**build**). pip installs are wheels only
   (`--only-binary :all:`) and `uv sync` runs with `--no-build`.
4. **Cooldown** (**review** until M3): take new upstream releases only after 3 days, except
   security fixes (Renovate `minimumReleaseAge` *(M3)*).
5. **Updates are reviewed commits** (**review**). Lockfiles and pins are regenerated with the
   commands written at the top of each `.in` file or in role defaults, never edited by hand.

## 4. Gates

| When | Gate | Fails on |
|---|---|---|
| every PR (`make lint`) | yamllint, profiles consistency, ansible-lint, syntax check, actionlint, **zizmor**, shellcheck, Actions pinned by SHA | any finding (zizmor: medium and above) |
| every PR (`make scan`) | **Trivy** vulnerabilities | CRITICAL with a fixed version |
| every PR (`make scan`) | **Trivy** secrets | any secret in any layer |
| every PR (`make scan`) | **OSV-Scanner** on all lockfiles and on every image, always with `security/osv-scanner.toml` | any `MAL-` (malicious package) advisory; a scan that finds no packages or returns an unreadable report. `MAL-` is **never ignorable**: `make lint` rejects any other `osv-scanner.toml` |
| every PR (`make check`) | check mode on each image | any change reported |
| every Monday (`weekly.yml`) | `make refresh`: from-scratch build with current updates, then all of the above | any failure opens one issue |
| *(v0.2)* publish | SBOM + provenance, cosign signature, weekly ratchet, nightly rescan, ClamAV | planned |

## 5. Exceptions

- Accepted vulnerability findings go in `security/trivyignore.yaml`, one entry per finding, with
  the ID, a reason (not reachable, or no fix yet), and an expiry at most 30 days out. Trivy itself
  drops expired entries; a check that fails on reasonless or far-future entries
  (`check-ignores.py`) is still to come *(M9)*.
- Every new exception needs review by a second maintainer (**review**).
- Malicious packages and leaked secrets are never exceptions: they are incidents (section 8).
- *(v0.2)* accepted findings are also published as OpenVEX next to the SBOM.

## 6. Adding a dependency

A PR that adds a package, download or Action answers in its description:
why it's needed; who maintains it (OpenSSF Scorecard and recent maintainer changes); whether it has
install scripts; its licence; what else was considered. It also adds the pin (section 3) and, for a
new source, a row in section 2.

## 7. Threat model (summary)

| Asset | Threat | Controls today | Planned |
|---|---|---|---|
| npm CLIs (Codex, Claude Code) | compromised maintainer or malicious transitive dependency | lockfile with integrity hashes; `npm ci --ignore-scripts`; reviewed script allow-list; OSV `MAL-` gate | 3-day cooldown (Renovate); `make deps-risk` (Scorecard, provenance, maintainer changes) |
| Base image | poisoned or moved tag | digest pin; `apt-get upgrade` from signed archive | Renovate digest bumps |
| Binary downloads | tampered release asset | sha256 pin from checksum files or GitHub digests; fail on unknown version | signature checks where upstream signs |
| PyPI tools | malicious package or version | hashes, wheels only; OSV gate | cooldown |
| CI workflows and tokens | compromised Action, token theft, injection | Actions by SHA; zizmor; least-privilege permissions; no persisted credentials | Scorecard Action |
| Built images | vulnerable or secret-bearing layers | Trivy gates; weekly fresh rebuild | signed images, SBOM, nightly rescan |
| Running workspaces | API keys exposed | keys only from the environment at start; never in images | per-workspace env file (M6/M7) |

## 8. Compromised dependency: what we do

1. **Trigger:** an OSV `MAL-` hit, a public report, or a scanner issue.
2. **Triage** (same day): which images and lockfiles contain it, since when, and whether code ran
   at build time (install script) or was only shipped.
3. **Contain:** pin to the last good version or remove it; rebuild affected images; once images
   are published *(v0.2)*, move tags to the clean digest and list bad digests in the release notes.
4. **Rotate:** if a build step ran the malicious code, rotate CI secrets and review workflow runs
   since the bad version arrived.
5. **Communicate:** a GitHub Security Advisory with affected images and the fix; tell users to
   rebuild or pull, recreate workspaces, and rotate any API keys used in an affected workspace.
6. **Report upstream:** to the registry's security team and the package maintainers.

## 9. Review

This policy is reviewed every quarter and whenever a gate or source changes.

## 10. Known gaps

| Gap | Risk | Plan |
|---|---|---|
| LazyVim plugins (about 30) are installed at their current upstream commits by `Lazy! sync`, and lazy.nvim itself from its `stable` branch | a compromised plugin release runs its build hook at image build time | committed `lazy-lock.json`, restore only (M4); the build step gets no GitHub token |
| Python and Node versions are major/minor (`3.12`, `24`), resolved by mise at build time | a different patch release on each fresh build | `mise.lock` (M3) |
| npm itself comes with Node; the Dockerfile frontend is BuildKit's built-in one | not pinned separately | covered by the Node and BuildKit pins (M3) |
| OSV image scans see OS and language packages, not git-cloned plugins, native binaries or the custom image | malware in those isn't detected by OSV | pins above; ClamAV scan *(v0.2)* |
| The gates depend on osv.dev and Trivy's database being reachable | a scan can't run offline | the gates fail closed (no result is a failure) |
