# OpenBake. Needs only Docker >= 24 with buildx (Docker Desktop, OrbStack,
# Colima and Docker Engine all include it). Ansible runs inside the build.
#
#   make image                       build devbox, data and agent for this machine
#   make image PROFILE=agent         build one image (or several: PROFILE="minimal agent")
#   make smoke [PROFILE=devbox]      check images
#   make custom FROM=agent ROLES=hello_custom [VARS='{"hello_custom_packages":["htop"]}']
#   make run-devbox                  code-server on http://127.0.0.1:13337 (PASSWORD=...)
#   make run-data | run-agent        temporary until `make up` (M6)
#
# Images are ws-<profile>:$(WS_TAG). Build settings are WS_* variables, see
# images/docker-bake.hcl, e.g.
#   WS_PYTHON_VERSIONS='["3.13","3.12"]' make image PROFILE=devbox

WS_REGISTRY ?=
WS_TAG      ?= local
PASSWORD    ?= change-me
BAKE        := docker buildx bake -f images/docker-bake.hcl --load $(BAKE_ARGS)
export WS_REGISTRY WS_TAG

ref = $(if $(WS_REGISTRY),$(WS_REGISTRY)/)ws-$(1):$(WS_TAG)

.DEFAULT_GOAL := help
.PHONY: help image smoke custom run-devbox run-data run-agent prune-cache

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

image:
	$(BAKE) $(or $(PROFILE),default)

smoke:
	bash images/smoke.sh $(PROFILE)

custom:
	@test -n "$(ROLES)" || { echo "usage: make custom FROM=<profile> ROLES=<role>[,<role>]" >&2; exit 2; }
	WS_CUSTOM_FROM=$(or $(FROM),devbox) WS_CUSTOM_ROLES=$(ROLES) WS_CUSTOM_VARS='$(VARS)' $(BAKE) custom

run-devbox:
	docker run --rm -it -p 127.0.0.1:13337:13337 -e PASSWORD=$(PASSWORD) \
	  -v ws-devbox-home:/home/user $(call ref,devbox)

run-data:
	docker run --rm -it -p 127.0.0.1:3000:3000 -p 127.0.0.1:8501:8501 \
	  -v ws-data-home:/home/user $(call ref,data)

run-agent:
	docker run --rm -it -e ANTHROPIC_API_KEY -e OPENAI_API_KEY \
	  -v ws-agent-home:/home/user $(call ref,agent)

# BuildKit keeps apt/npm/uv/download caches between builds; this clears them.
prune-cache:
	docker buildx prune --filter type=exec.cachemount -f
