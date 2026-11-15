# OpenBake. Needs only Docker >= 25 with buildx (Docker Desktop, OrbStack,
# Colima and Docker Engine all include it). Ansible runs inside the build.
#
#   make image                       build devbox, data and agent for this machine
#   make image PROFILE=agent         build one image (or several: PROFILE="minimal agent")
#   make smoke [PROFILE=devbox]      check images
#   make lint                        yamllint, profiles consistency, ansible-lint, --syntax-check, actionlint, zizmor, shellcheck
#   make check [PROFILE=devbox]      re-apply an image's roles with --check: must report changed=0
#   make scan [PROFILE=devbox]       Trivy (CRITICAL with a fix, secrets) + OSV (malicious packages) gate
#   make ci [PROFILE=devbox]         everything CI runs, in the same order (lint image smoke check scan)
#   make refresh [PROFILE=devbox]    rebuild from scratch (pinned base + today's security updates),
#                                    then smoke, check and scan. A plain `make image` reuses cached layers.
#   make custom FROM=agent ROLES=hello_custom [VARS='{"hello_custom_packages":["htop"]}']
#   make run-devbox                  code-server on http://127.0.0.1:13337 (PASSWORD=...)
#   make run-data | run-agent        temporary until `make up` (M6)
#   make sandbox-up | sandbox-down   agent with no internet and no real credentials, behind a broker
#   make sandbox-shell               shell in the sandboxed agent
#   make sandbox-check               boundary tests: fails on any leak
#                                    SANDBOX_RUNTIME=docker (default) | apple (Apple `container`, experimental)
#
# Images are ws-<profile>:$(WS_TAG). Build settings are WS_* variables, see
# images/docker-bake.hcl, e.g.
#   WS_PYTHON_VERSIONS='["3.13","3.12"]' make image PROFILE=devbox

# bash with pipefail, so a failing command on the left of a pipe fails the
# recipe (docker save | docker run in scan). bash ships with macOS and Linux.
SHELL := bash
.SHELLFLAGS := -o pipefail -c

WS_REGISTRY ?=
WS_TAG      ?= local
PASSWORD    ?= change-me
BAKE        := docker buildx bake -f images/docker-bake.hcl --load $(BAKE_ARGS)
BAKE_NOLOAD := docker buildx bake -f images/docker-bake.hcl $(BAKE_ARGS)
export WS_REGISTRY WS_TAG

ref = $(if $(WS_REGISTRY),$(WS_REGISTRY)/)ws-$(1):$(WS_TAG)

.DEFAULT_GOAL := help
.PHONY: help image smoke lint check check-ci scan ci refresh custom run-devbox run-data run-agent prune-cache \
	sandbox-up sandbox-down sandbox-shell sandbox-check

LINT_IMAGE    = $(call ref,lint)
SCAN_IMAGE    = $(call ref,scan)
SCAN_PROFILES ?= minimal devbox data agent
# Lockfiles checked for malicious packages (OSV MAL- advisories) by make scan.
OSV_LOCKFILES = -L /src/ansible/roles/agents/files/package-lock.json \
	-L /src/ansible/roles/data_sample/files/streamlit-dagster/uv.lock \
	-L requirements.txt:/src/images/requirements/ansible.txt \
	-L requirements.txt:/src/images/requirements/lint.txt \
	-L requirements.txt:/src/ansible/roles/runtimes/files/uv-requirements.txt
TRIVY = docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
	  -v ws-trivy-cache:/root/.cache/trivy -v "$(CURDIR)/security:/security:ro" \
	  $(SCAN_IMAGE) image --ignorefile /security/trivyignore.yaml --exit-code 1 --no-progress
# Check-mode policy shared by CI and `make ci`: blocking profiles fail the run;
# report-only profiles only warn (use for a profile whose roles are being reworked).
CHECK_BLOCKING    ?= minimal devbox data agent
CHECK_REPORT_ONLY ?=

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

image:
	$(BAKE) $(or $(PROFILE),default)

smoke:
	CUSTOM_ROLES="$(CUSTOM_ROLES)" bash images/smoke.sh $(PROFILE)

# All tools run in a container built from the Dockerfile `lint` stage.
lint:
	docker buildx bake -f images/docker-bake.hcl --print minimal devbox data agent custom lint check scan > /dev/null
	$(BAKE) lint
	docker run --rm -v "$(CURDIR):/src:ro" -e ANSIBLE_ROLES_PATH=/src/custom/roles:/src/ansible/roles \
	  -e ANSIBLE_CONFIG=/src/ansible/ansible.cfg -e HOME=/tmp $(LINT_IMAGE) sh -euc '\
	    echo "== yamllint"; yamllint --strict .; \
	    echo "== profiles consistency"; python3 scripts/profiles-consistency.py; \
	    echo "== ansible-playbook --syntax-check"; \
	    ansible-playbook --syntax-check -i localhost, ansible/apply.yml -e ws_roles=base; \
	    ansible-playbook --syntax-check -i localhost, tests/syntax-check.yml; \
	    echo "== ansible-lint"; ansible-lint; \
	    echo "== actionlint"; actionlint; \
	    echo "== zizmor (GitHub workflow security)"; zizmor --offline --min-severity medium .github/workflows; \
	    echo "== npm lockfile"; python3 scripts/check-npm-lock.py; \
	    echo "== no stray osv-scanner.toml"; \
	    if find . -name osv-scanner.toml ! -path ./security/osv-scanner.toml -not -path "./.git/*" | grep .; then \
	      echo "osv-scanner.toml outside security/ could hide findings" >&2; exit 1; fi; \
	    echo "== actions pinned to commit SHAs"; \
	    if grep -rnE "uses: *[^ ]+@" .github/workflows | grep -vE "@[0-9a-f]{40}( |$$)"; then \
	      echo "unpinned action(s) above: pin to a full commit SHA" >&2; exit 1; fi; \
	    echo "== shellcheck"; shellcheck images/smoke.sh tests/check-mode.sh ansible/apply.sh .github/scripts/*.sh \
	      ansible/roles/base/files/ws-init ansible/roles/base/files/ws-info \
	      sandbox/sandbox.sh sandbox/broker/entrypoint.sh'

# check with the CI policy (blocking vs report-only), limited to PROFILE when given.
CI_SELECTED = $(or $(PROFILE),$(CI_PROFILES))
check-ci:
	$(if $(filter $(CHECK_BLOCKING),$(CI_SELECTED)),$(MAKE) check PROFILE="$(filter $(CHECK_BLOCKING),$(CI_SELECTED))")
	@for p in $(filter $(CHECK_REPORT_ONLY),$(CI_SELECTED)); do \
	  $(MAKE) check PROFILE=$$p || echo "::warning::check mode not clean for $$p (report-only)"; \
	done

# Same steps as .github/workflows/ci.yml; CI only adds runners, caching and the arch matrix.
CI_PROFILES ?= minimal devbox data agent
ci:
	$(MAKE) lint
	$(MAKE) image PROFILE="$(CI_SELECTED)"
	$(MAKE) smoke PROFILE="$(CI_SELECTED)"
	$(MAKE) check-ci PROFILE="$(CI_SELECTED)"
	$(MAKE) scan PROFILE="$(CI_SELECTED)"
	$(if $(filter devbox,$(CI_SELECTED)),$(MAKE) custom FROM=devbox ROLES=hello_custom && $(MAKE) smoke PROFILE=custom CUSTOM_ROLES=hello_custom)

# Builds the `check` stage on top of the image stage (from the build cache: run make image first).
check:
	@for p in $(or $(PROFILE),minimal devbox data agent); do \
	  test -f "ansible/profiles/$$p.yml" || { echo "make check: no profile ansible/profiles/$$p.yml" >&2; exit 2; }; \
	  echo "== check mode: $$p"; \
	  WS_CUSTOM_FROM=$$p WS_CHECK_PROFILE=$$p $(BAKE_NOLOAD) check || exit 1; \
	done

# Trivy runs in a container and reads images through the Docker socket.
# Two passes, because --severity also filters secret findings: vulnerabilities
# fail on CRITICAL with a fixed version; secrets fail at any severity.
# Accepted findings go in security/trivyignore.yaml (each with a reason and expiry).
scan:
	$(BAKE) scan
	@echo "== osv: malicious packages in lockfiles"
	@docker run --rm --entrypoint sh -v "$(CURDIR):/src:ro" $(SCAN_IMAGE) -c '\
	  osv-scanner scan source --config /src/security/osv-scanner.toml $(OSV_LOCKFILES) \
	    --format json --output-file /tmp/osv.json > /tmp/osv.log 2>&1; rc=$$?; \
	  python3 /src/security/osv-gate.py /tmp/osv.json $$rc lockfiles || { tail -20 /tmp/osv.log; exit 1; }'
	@for p in $(or $(PROFILE),$(SCAN_PROFILES)); do \
	  img="$(if $(WS_REGISTRY),$(WS_REGISTRY)/)ws-$$p:$(WS_TAG)"; \
	  echo "== trivy: $$img"; \
	  $(TRIVY) --scanners vuln --severity CRITICAL --ignore-unfixed "$$img" || exit 1; \
	  $(TRIVY) --scanners secret "$$img" || exit 1; \
	  echo "== osv: malicious packages in $$img"; \
	  docker save "$$img" | docker run -i --rm --entrypoint sh -v "$(CURDIR)/security:/security:ro" $(SCAN_IMAGE) -c '\
	    cat > /tmp/image.tar && \
	    osv-scanner scan image --archive /tmp/image.tar --config /security/osv-scanner.toml \
	      --format json --output-file /tmp/osv.json > /tmp/osv.log 2>&1; rc=$$?; \
	    python3 /security/osv-gate.py /tmp/osv.json $$rc image || { tail -20 /tmp/osv.log; exit 1; }' || exit 1; \
	done

# Patching: --no-cache re-runs the os stage (apt-get upgrade) and every role, so
# the pinned ubuntu:24.04 digest gets today's security updates. The digest itself
# moves only through a reviewed commit (Renovate from M3). Weekly workflow runs this.
REFRESH_PROFILES ?= minimal devbox data agent
refresh:
	$(MAKE) image PROFILE="$(or $(PROFILE),$(REFRESH_PROFILES))" BAKE_ARGS="$(BAKE_ARGS) --pull --no-cache"
	$(MAKE) smoke PROFILE="$(or $(PROFILE),$(REFRESH_PROFILES))"
	$(MAKE) check PROFILE="$(or $(PROFILE),$(REFRESH_PROFILES))" BAKE_ARGS="$(BAKE_ARGS) --pull"
	$(MAKE) scan PROFILE="$(or $(PROFILE),$(REFRESH_PROFILES))"

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

# Sandbox experiment (sandbox/): needs the agent image (make image PROFILE=agent)
# and a credential in ~/.config/openbake/sandbox/secrets/llm_key (SANDBOX_STATE_DIR
# moves that directory). See sandbox/sandbox.sh.
SANDBOX_RUNTIME ?= docker
sandbox-up sandbox-down sandbox-shell sandbox-check:
	SANDBOX_RUNTIME=$(SANDBOX_RUNTIME) bash sandbox/sandbox.sh $(@:sandbox-%=%)

# BuildKit keeps apt/npm/uv/download caches between builds; this clears them.
prune-cache:
	docker buildx prune --filter type=exec.cachemount -f
