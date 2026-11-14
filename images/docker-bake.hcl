# docker buildx bake               -> devbox, data, agent (base is shared, built once)
# docker buildx bake agent         -> one image
# WS_PLATFORMS=linux/amd64,linux/arm64 WS_REGISTRY=ghcr.io/acme/ws docker buildx bake --push
#
# Every variable can be set from the environment. They all start with WS_ so
# unrelated shell variables (TAG, CLAUDE_CODE_VERSION, ...) can't leak in.

variable "WS_REGISTRY" { default = "local/ws" }
variable "WS_TAG" { default = "dev" }
variable "WS_PLATFORMS" { default = "" }            # empty = this machine's platform
variable "WS_BASE_IMAGE" { default = "ubuntu:24.04" }

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

group "default" {
  targets = ["devbox", "data", "agent"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
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

target "base" {
  inherits = ["_common"]
  target   = "base"
  tags     = ["${WS_REGISTRY}/base:${WS_TAG}"]
}

target "devbox" {
  inherits = ["_common"]
  target   = "devbox"
  tags     = ["${WS_REGISTRY}/devbox:${WS_TAG}"]
}

target "data" {
  inherits = ["_common"]
  target   = "data"
  tags     = ["${WS_REGISTRY}/data:${WS_TAG}"]
}

target "agent" {
  inherits = ["_common"]
  target   = "agent"
  tags     = ["${WS_REGISTRY}/agent:${WS_TAG}"]
}

target "custom" {
  inherits = ["_common"]
  target   = "custom"
  tags     = ["${WS_REGISTRY}/custom:${WS_TAG}"]
  args = {
    CUSTOM_FROM     = WS_CUSTOM_FROM
    CUSTOM_ROLES    = WS_CUSTOM_ROLES
    WSV_CUSTOM_VARS = WS_CUSTOM_VARS
  }
}
