#!/usr/bin/env bash
# Runs after a subagent stops. Validates the newest handoff.json against schema
# and blocks the pipeline if the gate did not pass.
set -euo pipefail

HANDOFF=$(ls -t handoff*.json 2>/dev/null | head -1 || true)
if [ -z "${HANDOFF:-}" ]; then
  echo "gate-check: no handoff.json found yet — skipping." >&2
  exit 0
fi

# schema validation (requires: pip install check-jsonschema, or npx ajv)
if command -v check-jsonschema >/dev/null 2>&1; then
  check-jsonschema --schemafile shared/schemas/handoff.schema.json "$HANDOFF" \
    || { echo "gate-check: $HANDOFF failed schema validation" >&2; exit 2; }
fi

STATUS=$(python3 -c "import json,sys;print(json.load(open('$HANDOFF'))['status'])")
SCORE=$(python3 -c "import json;print(json.load(open('$HANDOFF'))['gate']['score'])")

echo "gate-check: $HANDOFF status=$STATUS score=$SCORE"
if [ "$STATUS" = "failed" ]; then
  echo "GATE FAILED — pipeline must route back to owning stage." >&2
  exit 2
fi
exit 0
