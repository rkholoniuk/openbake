# Run from the repo root (the Makefile does this):
#
#   docker buildx bake -f images/docker-bake.hcl --load            devbox, data, agent
#   docker buildx bake -f images/docker-bake.hcl --load agent      one image
#   WS_PLATFORMS=linux/amd64,linux/arm64 WS_REGISTRY=ghcr.io/rkh0x7ea/openbake \
#     docker buildx bake -f images/docker-bake.hcl --push
#
# Images are named ws-<profile>:<WS_TAG>, prefixed with WS_REGISTRY/ when it is set.
#
# Every variable can be set from the environment. They all start with WS_ so
# unrelated shell variables (TAG, CLAUDE_CODE_VERSION, ...) can't leak in.

variable "WS_REGISTRY" { default = "" }             # empty = local image names only
variable "WS_TAG" { default = "local" }
variable "WS_PLATFORMS" { default = "" }            # empty = this machine's platform
variable "WS_BASE_IMAGE" { default = "ubuntu:24.04" }

# Per-version overrides (spike mechanism; replaced by versions.yml + WS_EXTRA_VARS in M3).
# Empty means "use the role default". Lists are JSON.
variable "WS_RUNTIMES_INSTALLER" { default = "" }   # mise | system
variable "WS_PYTHON_VERSIONS" { default = "" }      # e.g. ["3.13","3.12"]  (first = default)
variable "WS_NODE_VERSIONS" { default = "" }        # e.g. ["24"]
variable "WS_NEOVIM_VERSION" { default = "" }       # e.g. v0.11.5
variable "WS_CODE_SERVER_VERSION" { default = "" }
variable "WS_CODE_SERVER_EXTENSIONS" { default = "" }  # e.g. ["ms-python.python"]
variable "WS_CODEX_VERSION" { default = "" }
variable "WS_CLAUDE_CODE_VERSION" { default = "" }
variable "WS_GIT_KNOWN_HOSTS_SOURCE" { default = "" }  # github_meta | static | none

# Custom images: start from a curated stage and add roles (yours live in custom/roles).
variable "WS_CUSTOM_FROM" { default = "devbox" }
variable "WS_CUSTOM_ROLES" { default = "" }
variable "WS_CUSTOM_VARS" { default = "" }          # JSON object of extra role variables

function "image" {
  params = [profile]
  result = WS_REGISTRY == "" ? "ws-${profile}:${WS_TAG}" : "${WS_REGISTRY}/ws-${profile}:${WS_TAG}"
}

group "default" {
  targets = ["devbox", "data", "agent"]
}

target "_common" {
  context    = "."
  dockerfile = "images/Dockerfile"
  platforms  = WS_PLATFORMS == "" ? [] : split(",", WS_PLATFORMS)
  # Optional: raises GitHub's API rate limit for mise. Never stored in a layer.
  secret = ["id=github_token,env=GITHUB_TOKEN"]
  args = {
    BASE_IMAGE                 = WS_BASE_IMAGE
    WSV_RUNTIMES_INSTALLER     = WS_RUNTIMES_INSTALLER
    WSV_PYTHON_VERSIONS        = WS_PYTHON_VERSIONS
    WSV_NODE_VERSIONS          = WS_NODE_VERSIONS
    WSV_NEOVIM_VERSION         = WS_NEOVIM_VERSION
    WSV_CODE_SERVER_VERSION    = WS_CODE_SERVER_VERSION
    WSV_CODE_SERVER_EXTENSIONS = WS_CODE_SERVER_EXTENSIONS
    WSV_CODEX_VERSION          = WS_CODEX_VERSION
    WSV_CLAUDE_CODE_VERSION    = WS_CLAUDE_CODE_VERSION
    WSV_GIT_KNOWN_HOSTS_SOURCE = WS_GIT_KNOWN_HOSTS_SOURCE
  }
}

target "minimal" {
  inherits = ["_common"]
  target   = "minimal"
  tags     = [image("minimal")]
}

target "devbox" {
  inherits = ["_common"]
  target   = "devbox"
  tags     = [image("devbox")]
}

target "data" {
  inherits = ["_common"]
  target   = "data"
  tags     = [image("data")]
}

target "agent" {
  inherits = ["_common"]
  target   = "agent"
  tags     = [image("agent")]
}

target "custom" {
  inherits = ["_common"]
  target   = "custom"
  tags     = [image("custom")]
  args = {
    CUSTOM_FROM     = WS_CUSTOM_FROM
    CUSTOM_ROLES    = WS_CUSTOM_ROLES
    WSV_CUSTOM_VARS = WS_CUSTOM_VARS
  }
}
