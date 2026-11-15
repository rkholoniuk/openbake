# Workspace images built from Ansible roles.
#
# Each role runs in its own RUN step, so editing one role only rebuilds the
# layers from that role onwards. Ansible itself is bind-mounted from the
# `ansible` stage and never ends up in an image. apt, npm, pip/uv and download
# caches are BuildKit cache mounts, so warm rebuilds don't hit the network.
#
# Targets: minimal, devbox, data, agent, custom.  See images/docker-bake.hcl.
# Build context is the repo root (bake sets it); paths below are repo-relative.
# Every apply.sh call passes -e ws_target=image: roles behave differently on
# real machines (ws_target=host, see docs/design/phase1-design.md 6.3).

# Pinned by digest (multi-arch index, Docker Hub 2026-11-12). Bumped by a reviewed
# commit (Renovate from M3); weekly `make refresh` still applies security updates
# on top through `apt-get upgrade` in the os stage.
ARG BASE_IMAGE=ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
# Set by BuildKit; used to pick per-architecture downloads (scan stage).
ARG TARGETARCH
# Global so the `custom` stage can start FROM any curated stage (minimal, devbox, data, agent).
ARG CUSTOM_FROM=devbox

# ---------------------------------------------------------------------------
# os: the distro plus the one thing Ansible needs on the target (Python + apt bindings)
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS os
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
 && apt-get update \
 && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends python3 python3-apt ca-certificates
# `apt-get upgrade` brings packages inherited from ubuntu:24.04 up to today's
# security updates. Normal builds reuse this cached layer; `make refresh`
# (--no-cache) re-runs it, which is how the weekly rebuild patches them.

# ---------------------------------------------------------------------------
# ansible: ansible-core in a venv; bind-mounted into later RUN steps only
# ---------------------------------------------------------------------------
FROM os AS ansible
# ansible-core 2.21 is the newest line that runs on Ubuntu 24.04's Python 3.12
# (2.22 needs 3.13). Every package is pinned by version and sha256, wheels only
# (images/requirements/ansible.txt, generated from ansible.in).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends python3-venv
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=bind,source=images/requirements/ansible.txt,target=/tmp/ansible.txt \
    python3 -m venv /opt/ansible/venv \
 && /opt/ansible/venv/bin/pip install --require-hashes --only-binary :all: -r /tmp/ansible.txt
COPY ansible/ansible.cfg ansible/apply.yml ansible/apply.sh /opt/ansible/
# Profiles are read by apply.yml (-e ws_profile=...). A profile edit rebuilds
# every role layer; images rebuild weekly anyway, role edits still rebuild
# only from that role on.
COPY ansible/profiles/ /opt/ansible/profiles/
RUN chmod 0755 /opt/ansible/apply.sh

# ---------------------------------------------------------------------------
# minimal: user, core packages, git
# ---------------------------------------------------------------------------
FROM os AS minimal
ARG WSV_GIT_KNOWN_HOSTS_SOURCE
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/base,target=/opt/roles/base \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /opt/ansible/apply.sh base -e ws_target=image
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/git,target=/opt/roles/git \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /opt/ansible/apply.sh git -e ws_target=image
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/cli_tools,target=/opt/roles/cli_tools \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    /opt/ansible/apply.sh cli_tools -e ws_target=image
ENV MISE_DATA_DIR=/opt/mise \
    PATH=/opt/mise/shims:/opt/agents/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /home/user
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ws-init"]
USER user
CMD ["bash", "-l"]

# Shared by every image that needs Python/Node. Versions come from build args.
FROM minimal AS runtimes
ARG WSV_RUNTIMES_INSTALLER
ARG WSV_PYTHON_VERSIONS
ARG WSV_NODE_VERSIONS
USER root
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/runtimes,target=/opt/roles/runtimes \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    --mount=type=cache,target=/root/.cache/pip \
    --mount=type=secret,id=github_token,required=false \
    /opt/ansible/apply.sh runtimes -e ws_target=image

# ---------------------------------------------------------------------------
# devbox: code-server, Neovim + LazyVim, Python and Node versions, git
# ---------------------------------------------------------------------------
FROM runtimes AS devbox
ARG WSV_NEOVIM_VERSION
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/neovim,target=/opt/roles/neovim \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    --mount=type=secret,id=github_token,required=false \
    /opt/ansible/apply.sh neovim -e ws_target=image -e ws_profile=devbox
ARG WSV_CODE_SERVER_VERSION
ARG WSV_CODE_SERVER_EXTENSIONS
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/code_server,target=/opt/roles/code_server \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    /opt/ansible/apply.sh code_server -e ws_target=image -e ws_profile=devbox
USER user
CMD ["ws-code-server"]

# ---------------------------------------------------------------------------
# data: Postgres + the Streamlit/Dagster sample pipeline
# ---------------------------------------------------------------------------
FROM runtimes AS data
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/postgres,target=/opt/roles/postgres \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /opt/ansible/apply.sh postgres -e ws_target=image -e ws_profile=data
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/data_sample,target=/opt/roles/data_sample \
    --mount=type=cache,target=/var/cache/uv,sharing=locked \
    /opt/ansible/apply.sh data_sample -e ws_target=image -e ws_profile=data
USER user
CMD ["ws-sample-data", "start", "--foreground"]

# ---------------------------------------------------------------------------
# agent: git, Python, Node, Codex, Claude Code
# ---------------------------------------------------------------------------
FROM runtimes AS agent
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/agents,target=/opt/roles/agents \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    /opt/ansible/apply.sh agents -e ws_target=image -e ws_profile=agent
USER user
CMD ["bash", "-l"]

# ---------------------------------------------------------------------------
# custom: any curated image + your own roles, in one fast layer
#   docker buildx bake custom --set custom.args.CUSTOM_FROM=devbox \
#     --set custom.args.CUSTOM_ROLES=agents,myrole
# ---------------------------------------------------------------------------
FROM ${CUSTOM_FROM} AS custom
ARG CUSTOM_ROLES
ARG WSV_CUSTOM_VARS
USER root
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles,target=/opt/roles \
    --mount=type=bind,source=custom/roles,target=/opt/custom-roles \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    --mount=type=secret,id=github_token,required=false \
    test -n "${CUSTOM_ROLES}" || { echo "CUSTOM_ROLES is empty" >&2; exit 1; }; \
    ANSIBLE_ROLES_PATH=/opt/custom-roles:/opt/roles /opt/ansible/apply.sh "${CUSTOM_ROLES}" -e ws_target=image
USER user

# ---------------------------------------------------------------------------
# Test stages (not images). Run with `make lint` and `make check PROFILE=...`.
# ---------------------------------------------------------------------------

# actionlint (GitHub workflow linter), pinned by version and sha256 per arch.
FROM os AS actionlint-amd64
ADD --checksum=sha256:8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 \
    https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz /tmp/actionlint.tgz
FROM os AS actionlint-arm64
ADD --checksum=sha256:325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 \
    https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz /tmp/actionlint.tgz
FROM actionlint-${TARGETARCH} AS actionlint
RUN tar -xzf /tmp/actionlint.tgz -C /usr/local/bin actionlint

# lint: ansible-core from the ansible stage plus ansible-lint, yamllint, zizmor, actionlint, shellcheck.
# `make lint` runs this image with the repo mounted read-only.
FROM ansible AS lint
# ansible-lint, yamllint, zizmor: pinned by version and sha256, wheels only
# (images/requirements/lint.txt, generated from lint.in).
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=bind,source=images/requirements/lint.txt,target=/tmp/lint.txt \
    /opt/ansible/venv/bin/pip install --require-hashes --only-binary :all: -r /tmp/lint.txt \
 && apt-get update && apt-get install -y --no-install-recommends git shellcheck && rm -rf /var/lib/apt/lists/*
COPY --from=actionlint /usr/local/bin/actionlint /usr/local/bin/actionlint
ENV PATH=/opt/ansible/venv/bin:$PATH
WORKDIR /src

# check: re-apply a finished image's profile (all its roles) in check mode (--check --diff).
# A built image must already be in the state its roles describe, so the run
# has to report changed=0. Catches roles that would change things on every
# run, and roles that break in check mode (which `make host CHECK=1` relies on).
FROM ${CUSTOM_FROM} AS check
ARG CHECK_PROFILE
# Same role variables as the build (empty = role default).
ARG WSV_GIT_KNOWN_HOSTS_SOURCE
ARG WSV_RUNTIMES_INSTALLER
ARG WSV_PYTHON_VERSIONS
ARG WSV_NODE_VERSIONS
ARG WSV_NEOVIM_VERSION
ARG WSV_CODE_SERVER_VERSION
ARG WSV_CODE_SERVER_EXTENSIONS
USER root
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles,target=/opt/roles \
    --mount=type=bind,source=custom/roles,target=/opt/custom-roles \
    --mount=type=bind,source=tests/check-mode.sh,target=/opt/check-mode.sh \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    test -n "${CHECK_PROFILE}" || { echo "CHECK_PROFILE is empty" >&2; exit 1; }; \
    ANSIBLE_ROLES_PATH=/opt/custom-roles:/opt/roles sh /opt/check-mode.sh "${CHECK_PROFILE}"

# scan: Trivy for the image gate (`make scan`). Version and sha256 are pinned
# here (versions.yml from M3). Trivy's own release channel was compromised in
# March 2026 (CVE-2026-33634), so we never use a moving tag or the
# trivy-action/setup-trivy GitHub Actions; the release tarball is checked
# against a checksum reviewed in this repo.
FROM os AS trivy-amd64
ADD --checksum=sha256:c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0 \
    https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz /tmp/trivy.tgz
FROM os AS trivy-arm64
ADD --checksum=sha256:e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f \
    https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-ARM64.tar.gz /tmp/trivy.tgz
# OSV-Scanner: malicious-package (MAL-) gate for image contents and lockfiles,
# which Trivy does not cover. Pinned by version and sha256 per arch.
FROM os AS osv-amd64
ADD --checksum=sha256:fb7dab19a8bd9bbe5c3189f09d4b7ee1820c9553a23bac202648a56efd2f6ee8 \
    https://github.com/google/osv-scanner/releases/download/v2.7.1/osv-scanner_linux_amd64 /usr/local/bin/osv-scanner
FROM os AS osv-arm64
ADD --checksum=sha256:983d22fbad9724514e3fcc6acc83b5fa64c5ffa6b0d9f510028f22c1b223ff81 \
    https://github.com/google/osv-scanner/releases/download/v2.7.1/osv-scanner_linux_arm64 /usr/local/bin/osv-scanner
FROM osv-${TARGETARCH} AS osv

FROM trivy-${TARGETARCH} AS scan
RUN tar -xzf /tmp/trivy.tgz -C /usr/local/bin trivy && rm /tmp/trivy.tgz && trivy --version
COPY --from=osv /usr/local/bin/osv-scanner /usr/local/bin/osv-scanner
RUN chmod 0755 /usr/local/bin/osv-scanner && osv-scanner --version
ENTRYPOINT ["trivy"]
