# Workspace images. Needs only Docker >= 24 with buildx
# (Docker Desktop, OrbStack, Colima and Docker Engine all include it).
#
#   make                 build devbox, data and agent for this machine
#   make agent           build one image
#   make run-devbox      code-server on http://localhost:13337 (PASSWORD=...)
#   make run-data        Dagster :3000, Streamlit :8501
#   make run-agent       shell with codex and claude
#   make custom FROM=agent ROLES=hello_custom
#   make smoke           check every image
#
# Build settings are WS_* variables, e.g.
#   WS_PYTHON_VERSIONS='["3.13","3.12"]' WS_NODE_VERSIONS='["24"]' make devbox

WS_REGISTRY ?= local/ws
WS_TAG      ?= dev
PASSWORD    ?= change-me
BAKE        := docker buildx bake --load
export WS_REGISTRY WS_TAG

.PHONY: all base devbox data agent custom run-devbox run-data run-agent smoke prune-cache

all:
	$(BAKE)

base devbox data agent:
	$(BAKE) $@

custom:
	WS_CUSTOM_FROM=$(or $(FROM),devbox) WS_CUSTOM_ROLES=$(ROLES) WS_CUSTOM_VARS='$(VARS)' $(BAKE) custom

run-devbox:
	docker run --rm -it -p 13337:13337 -e PASSWORD=$(PASSWORD) \
	  -v ws-devbox-home:/home/user $(WS_REGISTRY)/devbox:$(WS_TAG)

run-data:
	docker run --rm -it -p 3000:3000 -p 8501:8501 \
	  -v ws-data-home:/home/user $(WS_REGISTRY)/data:$(WS_TAG)

run-agent:
	docker run --rm -it -e ANTHROPIC_API_KEY -e OPENAI_API_KEY \
	  -v ws-agent-home:/home/user $(WS_REGISTRY)/agent:$(WS_TAG)

smoke:
	bash scripts/smoke.sh $(WS_REGISTRY) $(WS_TAG)

# BuildKit keeps apt/npm/uv/download caches between builds; this clears them.
prune-cache:
	docker buildx prune --filter type=exec.cachemount -f
