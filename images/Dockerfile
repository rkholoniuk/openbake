# Workspace images built from Ansible roles.
#
# Each role runs in its own RUN step, so editing one role only rebuilds the
# layers from that role onwards. Ansible itself is bind-mounted from the
# `ansible` stage and never ends up in an image. apt, npm, pip/uv and download
# caches are BuildKit cache mounts, so warm rebuilds don't hit the network.
#
# Targets: base, devbox, data, agent, custom.  See docker-bake.hcl.

ARG BASE_IMAGE=ubuntu:24.04
# Global so the `custom` stage can start FROM any curated stage (devbox, data, agent, base).
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
 && apt-get install -y --no-install-recommends python3 python3-apt ca-certificates

# ---------------------------------------------------------------------------
# ansible: ansible-core in a venv; bind-mounted into later RUN steps only
# ---------------------------------------------------------------------------
FROM os AS ansible
# 2.21 is the newest line that runs on Ubuntu 24.04's Python 3.12 (2.22 needs 3.13).
ARG ANSIBLE_CORE_VERSION=2.21.6
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get install -y --no-install-recommends python3-venv
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m venv /opt/ansible/venv \
 && /opt/ansible/venv/bin/pip install "ansible-core==${ANSIBLE_CORE_VERSION}"
COPY ansible/ansible.cfg ansible/apply.yml ansible/apply.sh /opt/ansible/
RUN chmod 0755 /opt/ansible/apply.sh

# ---------------------------------------------------------------------------
# base: user, core packages, git
# ---------------------------------------------------------------------------
FROM os AS base
ARG WSV_GIT_KNOWN_HOSTS_SOURCE
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/base,target=/opt/roles/base \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /opt/ansible/apply.sh base
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/git,target=/opt/roles/git \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /opt/ansible/apply.sh git
ENV MISE_DATA_DIR=/opt/mise \
    PATH=/opt/mise/shims:/opt/agents/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /home/user
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ws-init"]
CMD ["bash", "-l"]

# Shared by every image that needs Python/Node. Versions come from build args.
FROM base AS runtimes
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
    /opt/ansible/apply.sh runtimes

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
    /opt/ansible/apply.sh neovim
ARG WSV_CODE_SERVER_VERSION
ARG WSV_CODE_SERVER_EXTENSIONS
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/code_server,target=/opt/roles/code_server \
    --mount=type=cache,target=/var/cache/ws,sharing=locked \
    /opt/ansible/apply.sh code_server
USER user
EXPOSE 13337
CMD ["ws-code-server"]

# ---------------------------------------------------------------------------
# data: Postgres + the Streamlit/Dagster sample pipeline
# ---------------------------------------------------------------------------
FROM runtimes AS data
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/postgres,target=/opt/roles/postgres \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    /opt/ansible/apply.sh postgres
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/data_sample,target=/opt/roles/data_sample \
    --mount=type=cache,target=/var/cache/uv,sharing=locked \
    /opt/ansible/apply.sh data_sample
USER user
EXPOSE 3000 8501
CMD ["ws-sample-data", "start", "--foreground"]

# ---------------------------------------------------------------------------
# agent: git, Python, Node, Codex, Claude Code
# ---------------------------------------------------------------------------
FROM runtimes AS agent
ARG WSV_CODEX_VERSION
ARG WSV_CLAUDE_CODE_VERSION
RUN --mount=type=bind,from=ansible,source=/opt/ansible,target=/opt/ansible \
    --mount=type=bind,source=ansible/roles/agents,target=/opt/roles/agents \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    /opt/ansible/apply.sh agents
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
    ANSIBLE_ROLES_PATH=/opt/custom-roles:/opt/roles /opt/ansible/apply.sh "${CUSTOM_ROLES}"
USER user
