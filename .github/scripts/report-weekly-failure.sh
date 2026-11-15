#!/usr/bin/env bash
# Open (or comment on) one issue when the weekly refresh fails.
# Needs GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID.
set -euo pipefail

title="[weekly refresh] fresh image build, check or scan failed"
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
body="The weekly refresh (\`make refresh\`: new base image, current security updates, smoke, check mode, Trivy) failed.

Run: ${run_url}

Typical causes: a new CRITICAL vulnerability with a fix (update the pin or base image), a secret found in a layer, or a role that no longer applies cleanly."

# The title is passed through the environment, not spliced into the jq program.
existing="$(WEEKLY_TITLE="$title" gh issue list --repo "$GITHUB_REPOSITORY" --state open \
  --search "\"$title\" in:title" --json number,title \
  --jq '.[] | select(.title == env.WEEKLY_TITLE) | .number' | head -1)"

if [ -n "$existing" ]; then
  gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body "Failed again: ${run_url}"
  echo "commented on #$existing"
else
  gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body "$body"
fi
