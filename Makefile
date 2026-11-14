# OpenBake. Needs only Docker >= 24 with buildx (Docker Desktop, OrbStack,
# Colima and Docker Engine all include it). Ansible runs inside the build.
#
#   make image                       build devbox, data and agent for this machine
#   make image PROFILE=agent         build one image (or several: PROFILE="minimal agent")
#   make smoke [PROFILE=devbox]      check images
#   make lint                        yamllint, ansible-lint, ansible-playbook --syntax-check
#   make check [PROFILE=devbox]      re-apply an image's roles with --check: must report changed=0
#   make scan [PROFILE=devbox]       Trivy gate: fails on CRITICAL vulnerabilities with a fix, or secrets
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
BAKE_NOLOAD := docker buildx bake -f images/docker-bake.hcl $(BAKE_ARGS)
export WS_REGISTRY WS_TAG

ref = $(if $(WS_REGISTRY),$(WS_REGISTRY)/)ws-$(1):$(WS_TAG)

.DEFAULT_GOAL := help
.PHONY: help image smoke lint check scan custom run-devbox run-data run-agent prune-cache

# Roles per image, in layer order (replaced by ansible/profiles/*.yml in M2).
ROLES_minimal := base,git
ROLES_devbox  := base,git,runtimes,neovim,code_server
ROLES_data    := base,git,runtimes,postgres,data_sample
ROLES_agent   := base,git,runtimes,agents
LINT_IMAGE    := ws-lint:$(WS_TAG)
SCAN_IMAGE    := ws-scan:$(WS_TAG)
SCAN_PROFILES ?= minimal devbox data agent

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

image:
	$(BAKE) $(or $(PROFILE),default)

smoke:
	bash images/smoke.sh $(PROFILE)

# All tools run in a container built from the Dockerfile `lint` stage.
lint:
	$(BAKE) lint
	docker run --rm -v "$(CURDIR):/src:ro" -e ANSIBLE_ROLES_PATH=/src/custom/roles:/src/ansible/roles \
	  -e ANSIBLE_CONFIG=/src/ansible/ansible.cfg -e HOME=/tmp $(LINT_IMAGE) sh -euc '\
	    echo "== yamllint"; yamllint --strict .; \
	    echo "== ansible-playbook --syntax-check"; \
	    ansible-playbook --syntax-check -i localhost, ansible/apply.yml -e ws_roles=base; \
	    ansible-playbook --syntax-check -i localhost, tests/syntax-check.yml; \
	    echo "== ansible-lint"; ansible-lint'

# Builds the `check` stage on top of an existing image (build it first with make image).
check:
	@for p in $(or $(PROFILE),minimal devbox data agent); do \
	  roles="$$(case $$p in minimal) echo '$(ROLES_minimal)';; devbox) echo '$(ROLES_devbox)';; \
	    data) echo '$(ROLES_data)';; agent) echo '$(ROLES_agent)';; esac)"; \
	  test -n "$$roles" || { echo "make check: unknown profile $$p" >&2; exit 2; }; \
	  echo "== check mode: $$p ($$roles)"; \
	  WS_CUSTOM_FROM=$$p WS_CHECK_ROLES=$$roles $(BAKE_NOLOAD) check || exit 1; \
	done

# Trivy runs in a container and reads images through the Docker socket.
# Gate: CRITICAL vulnerabilities that have a fixed version, and secrets in layers.
# Accepted findings go in security/trivyignore.yaml (each with a reason and expiry).
scan:
	$(BAKE) scan
	@for p in $(or $(PROFILE),$(SCAN_PROFILES)); do \
	  echo "== trivy: $(if $(WS_REGISTRY),$(WS_REGISTRY)/)ws-$$p:$(WS_TAG)"; \
	  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
	    -v ws-trivy-cache:/root/.cache/trivy -v "$(CURDIR)/security:/security:ro" \
	    $(SCAN_IMAGE) image --scanners vuln,secret --severity CRITICAL --ignore-unfixed \
	    --ignorefile /security/trivyignore.yaml --exit-code 1 --no-progress \
	    $(if $(WS_REGISTRY),$(WS_REGISTRY)/)ws-$$p:$(WS_TAG) || exit 1; \
	done

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
