#!/usr/bin/env bash
# Sandbox control: ws-agent with no internet and no real credentials, plus the
# broker that holds the real LLM credential. Called by `make sandbox-*`.
#
#   sandbox.sh up | down | shell | check
#
# Local state (the real credential and the exchange folder) lives outside the
# repository: SANDBOX_STATE_DIR, default ~/.config/openbake/sandbox.
#
# SANDBOX_RUNTIME=docker (default) uses sandbox/compose.yaml.
# SANDBOX_RUNTIME=apple  uses Apple's `container` CLI (macOS 26, Apple silicon):
#   one VM per container. Experimental: tested once (container 1.7.1, macOS 26.3);
#   `check` is the judge.
set -euo pipefail

runtime="${SANDBOX_RUNTIME:-docker}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_image="${SANDBOX_AGENT_IMAGE:-ws-agent:local}"
state="${SANDBOX_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/openbake/sandbox}"
export SANDBOX_STATE_DIR="$state" # read by compose.yaml

# Apple backend names. The inner subnet is fixed so the broker's address can be found.
a_agent=openbake-sandbox-agent
a_broker=openbake-sandbox-broker
a_inner=openbake-sandbox-inner
a_home=openbake-sandbox-home
a_broker_image=openbake-sandbox-broker:local
a_subnet_prefix=10.89.0

die() { echo "sandbox: $*" >&2; exit 1; }

compose() { docker compose -f "$dir/compose.yaml" "$@"; }

preflight() {
  mkdir -p "$state/secrets" "$state/exchange"
  chmod 700 "$state" "$state/secrets"
  if git -C "$state" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    die "state directory $state is inside a git repository: set SANDBOX_STATE_DIR to a path outside any repo"
  fi
  # Earlier versions kept the credential in the repository.
  if [ ! -e "$state/secrets/llm_key" ] && [ -f "$dir/secrets/llm_key" ]; then
    mv "$dir/secrets/llm_key" "$state/secrets/llm_key"
    echo "sandbox: moved sandbox/secrets/llm_key to $state/secrets/llm_key"
  fi
  [ -s "$state/secrets/llm_key" ] \
    || die "$state/secrets/llm_key is missing or empty: put an API key or the \`claude setup-token\` value there"
  chmod 600 "$state/secrets/llm_key"
}

# ---------------------------------------------------------------- docker

docker_up() {
  docker image inspect "$agent_image" > /dev/null 2>&1 \
    || die "image $agent_image not found: run \`make image PROFILE=agent\` first"
  compose up -d --build
}

docker_down() { compose down; }

docker_exec() { compose exec -T agent "$@"; }

docker_shell() { compose exec agent bash -l; }

# ----------------------------------------------------------------- apple

apple_have() { container inspect "$1" > /dev/null 2>&1; }

apple_load_agent_image() {
  container image inspect "$agent_image" > /dev/null 2>&1 && return 0
  command -v docker > /dev/null 2>&1 \
    || die "image $agent_image is not in \`container\` and docker is not available to export it"
  echo "sandbox: copying $agent_image from docker to container"
  local tar
  tar="$(mktemp -t openbake-agent-image)"
  docker save "$agent_image" -o "$tar"
  container image load --input "$tar"
  rm -f "$tar"
}

apple_broker_ip() {
  container inspect "$a_broker" | grep -oE "${a_subnet_prefix//./\\.}\.[0-9]+" | grep -vE '\.(0|1|255)$' | head -1
}

apple_up() {
  container system status > /dev/null 2>&1 || container system start
  apple_load_agent_image
  container build --tag "$a_broker_image" "$dir/broker"

  container network inspect "$a_inner" > /dev/null 2>&1 \
    || container network create --internal --subnet "$a_subnet_prefix.0/24" "$a_inner"

  # A new volume is empty and root-owned; the workspace user is uid 1000.
  if ! container volume inspect "$a_home" > /dev/null 2>&1; then
    container volume create "$a_home"
    container run --rm --user 0 --entrypoint /bin/chown --volume "$a_home:/home/user" \
      "$agent_image" 1000:1000 /home/user
  fi

  # Broker: internet (default network) plus the inner network. It gets the
  # secrets directory read-only; the agent never does.
  if ! apple_have "$a_broker"; then
    container run --detach --name "$a_broker" \
      --network default --network "$a_inner" \
      --mount "type=bind,source=$state/secrets,target=/run/secrets,readonly" \
      "$a_broker_image"
  fi

  local ip
  ip="$(apple_broker_ip)" || true
  [ -n "$ip" ] || die "broker has no address on $a_inner (is a second --network supported?). Run \`make sandbox-down SANDBOX_RUNTIME=apple\`."

  if ! apple_have "$a_agent"; then
    container run --detach --name "$a_agent" \
      --network "$a_inner" \
      --read-only --tmpfs /tmp --cap-drop ALL \
      --env "ANTHROPIC_BASE_URL=http://$ip:8080" \
      --env "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-placeholder-real-token-lives-in-broker" \
      --env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
      --volume "$a_home:/home/user" \
      --volume "$state/exchange:/exchange" \
      "$agent_image" sleep infinity
  fi
}

apple_down() {
  container delete --force "$a_agent" "$a_broker" 2> /dev/null || true
  container network delete "$a_inner" 2> /dev/null || true
}

apple_exec() { container exec "$a_agent" "$@"; }

apple_shell() { container exec --interactive --tty "$a_agent" bash -l; }

# ----------------------------------------------------------------- check

# Runs inside the agent. Prints one line per test; exit 1 on any leak.
# shellcheck disable=SC2016  # expanded in the container, not here
check_script='
fail=0
ok()   { echo "ok:   $1"; }
leak() { echo "LEAK: $1"; fail=1; }

cred="${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${OPENAI_API_KEY:-}"
case "$cred" in
  "")            leak "no placeholder credential is set" ;;
  *placeholder*) ok "agent holds only a placeholder credential" ;;
  *)             leak "a real-looking credential is in the agent environment" ;;
esac

if [ -e /run/secrets/llm_key ]; then leak "broker secret is visible in the agent"; else ok "broker secret is not mounted"; fi

if curl -sS -m 5 -o /dev/null https://example.com 2> /dev/null; then leak "internet reachable by name"; else ok "no internet by name"; fi
if curl -sS -m 5 -o /dev/null https://1.1.1.1 2> /dev/null; then leak "internet reachable by address"; else ok "no internet by address"; fi

if sudo -n true 2> /dev/null; then leak "sudo works"; else ok "no sudo"; fi

if touch /usr/local/.sandbox-probe 2> /dev/null; then leak "root filesystem is writable"; else ok "read-only root filesystem"; fi

# The broker answers 403 for anything outside /v1/: reachable, and nothing is spent.
code="$(curl -s -m 10 -o /dev/null -w "%{http_code}" "${ANTHROPIC_BASE_URL:-http://broker:8080}/" 2> /dev/null || true)"
if [ "$code" = 403 ]; then ok "broker reachable"; else echo "FAIL: broker not reachable (http $code)"; fail=1; fi

exit "$fail"
'

# ------------------------------------------------------------------ main

case "$runtime" in
  docker | apple) ;;
  *) die "SANDBOX_RUNTIME must be docker or apple, got '$runtime'" ;;
esac

if [ "$runtime" = apple ] && ! command -v container > /dev/null 2>&1; then
  die "Apple's \`container\` CLI is not installed (macOS 26, Apple silicon): https://github.com/apple/container/releases"
fi

case "${1:-}" in
  up)
    preflight
    "${runtime}_up"
    echo "sandbox: up ($runtime), state in $state. Next: make sandbox-check, make sandbox-shell"
    ;;
  down) "${runtime}_down" ;;
  shell) "${runtime}_shell" ;;
  check)
    if "${runtime}_exec" sh -c "$check_script"; then
      echo "sandbox: all checks passed ($runtime)"
    else
      die "checks failed ($runtime)"
    fi
    ;;
  *) die "usage: sandbox.sh up|down|shell|check" ;;
esac
