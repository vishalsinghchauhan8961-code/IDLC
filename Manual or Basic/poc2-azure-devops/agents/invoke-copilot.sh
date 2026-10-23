#!/usr/bin/env bash
# Stub: assign a GitHub issue to the Copilot coding agent for this stage,
# or run the gh copilot CLI. Writes handoffs/<stage>.json.
set -euo pipefail
STAGE=$1; MODE=${2:-}
echo "TODO: wire to GitHub Copilot coding agent for stage=$STAGE mode=$MODE"
echo "See: gh api /repos/:owner/:repo/issues + assign @copilot with the chatmode."
