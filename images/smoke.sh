#!/usr/bin/env bash
# Smoke-test the images: tools present, versions recorded, sample pipeline works.
#   scripts/smoke.sh [registry] [tag] [images...]
set -euo pipefail

registry="${1:-local/ws}"
tag="${2:-dev}"
shift $(( $# > 2 ? 2 : $# ))
images=("$@")
[ ${#images[@]} -gt 0 ] || images=(devbox data agent)

failures=0
check() {  # check <image> <description> <command>
  local image="$1" what="$2" cmd="$3"
  if out=$(docker run --rm "$registry/$image:$tag" bash -lc "$cmd" 2>&1); then
    printf '  ok    %-28s %s\n' "$what" "$(echo "$out" | tail -1)"
  else
    printf '  FAIL  %-28s\n%s\n' "$what" "$(echo "$out" | sed 's/^/        /' | tail -15)"
    failures=$((failures + 1))
  fi
}

for image in "${images[@]}"; do
  echo "== $image ($(docker image inspect -f '{{.Size}}' "$registry/$image:$tag" | awk '{printf "%.0f MB", $1/1e6}'))"
  check "$image" "runs as user 1000"     'test "$(id -u)" = 1000 && id -un'
  check "$image" "git"                   'git --version'
  check "$image" "no ansible in image"   '! command -v ansible-playbook && ! test -e /opt/ansible && echo absent'
  check "$image" "python"                'python3 --version'
  check "$image" "uv"                    'uv --version'
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
  esac
  check "$image" "image manifest"        'ws-info | jq -c -s "map(.role)"'
done

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
