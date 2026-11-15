#!/usr/bin/env bash
# Check commands are single-quoted on purpose: they expand inside the container.
# shellcheck disable=SC2016
# Smoke-test images: tools present, versions recorded, sample pipeline works.
#   images/smoke.sh [profile...]        default: devbox data agent
# Images are ws-<profile>:$WS_TAG, prefixed with $WS_REGISTRY/ when set.
set -euo pipefail

tag="${WS_TAG:-local}"
prefix="${WS_REGISTRY:+$WS_REGISTRY/}"
images=("$@")
[ ${#images[@]} -gt 0 ] || images=(devbox data agent)

failures=0
check() {  # check <profile> <description> <command>
  local ref="${prefix}ws-$1:$tag" what="$2" cmd="$3"
  if out=$(docker run --rm "$ref" bash -lc "$cmd" 2>&1); then
    printf '  ok    %-28s %s\n' "$what" "$(echo "$out" | tail -1)"
  else
    printf '  FAIL  %-28s\n%s\n' "$what" "$(echo "$out" | sed 's/^/        /' | tail -15)"
    failures=$((failures + 1))
  fi
}

for image in "${images[@]}"; do
  ref="${prefix}ws-$image:$tag"
  echo "== $ref ($(docker image inspect -f '{{.Size}}' "$ref" | awk '{printf "%.0f MB", $1/1e6}'))"
  check "$image" "runs as user 1000"     'test "$(id -u)" = 1000 && id -un'
  check "$image" "git"                   'git --version'
  check "$image" "no ansible in image"   '! command -v ansible-playbook && ! test -e /opt/ansible && echo absent'
  check "$image" "python"                'python3 --version'
  check "$image" "cli tools"             'for t in rg fd bat tmux direnv jq; do command -v $t >/dev/null || { echo "missing $t"; exit 1; }; done; echo rg fd bat tmux direnv jq'
  check "$image" "yq"                    'yq --version'
  check "$image" "gh"                    'gh --version | head -1'
  check "$image" "uv (if runtimes)"      'if test -f /etc/ws-image/runtimes.json; then uv --version; else echo "n/a, no runtimes role"; fi'
  case "$image" in
    devbox)
      check devbox "node"                'node --version'
      check devbox "neovim"              'nvim --version | head -1'
      check devbox "lazyvim plugins"     'ls ~/.local/share/nvim/lazy | wc -l'
      check devbox "lazyvim headless"    'nvim --headless "+qa" && echo started'
      check devbox "code-server"         'code-server --version 2>/dev/null | grep -E "^[0-9]" | head -1'
      ;;
    data)
      check data "postgres + pipeline"   'ws-sample-data materialize >/tmp/m.log 2>&1 || { tail -20 /tmp/m.log; exit 1; }; psql -h /tmp -d analytics -tAc "select count(*) from daily_revenue"'
      check data "sample tests"          'cd ~/workspace/streamlit-dagster && uv run --frozen --group dev --no-progress pytest -q 2>&1 | tail -1'
      check data "streamlit imports"     '/opt/venvs/streamlit-dagster/bin/python -c "import streamlit, dagster; print(streamlit.__version__, dagster.__version__)"'
      ;;
    agent)
      check agent "node"                 'node --version'
      check agent "codex"                'codex --version'
      check agent "claude"               'claude --version'
      ;;
    custom)
      # CUSTOM_ROLES (comma-separated) names the roles that must have run.
      for r in ${CUSTOM_ROLES//,/ }; do
        check custom "role $r ran"       "test -f /etc/ws-image/$r.json && cat /etc/ws-image/$r.json"
      done
      if [[ ",${CUSTOM_ROLES:-}," == *",hello_custom,"* ]]; then
        check custom "hello_custom packages" 'htop --version | head -1 && command -v tree'
      fi
      ;;
  esac
  check "$image" "image manifest"        'ws-info | jq -c -s "map(.role)"'
done

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
