# IDLC Agent Team — Claude Code POC

This repo runs the **Intelligent-Driven Life Cycle (IDLC)**: human roles hand
off to specialized subagents that build a device-telemetry slice end to end.

## Pipeline
leadership → ui (Agent A) → platform (Agent B) → app (Agent C)
→ security (Agent C.2) → qa (Agent D)

Each agent reads the previous stage's `handoff.json`, does its work, writes a
new `handoff.json`. An agent MUST NOT start unless the upstream handoff
`status == "passed"`.

## Tech stack
Azure Functions (.NET isolated), Azure IoT Hub, Azure SQL, Angular frontend.
Terraform for infra. See `.claude/rules/` for conventions.

## Coordination modes (set IDLC_MODE env or pass to /idlc-run)
- `sequential` — each agent auto-invokes the next on pass
- `orchestrated` — the `idlc-orchestrator` agent decides who runs next
- `human` — pipeline pauses at each gate for your approval

## How to run
- `/idlc-run sequential` — full auto pipeline
- `/idlc-run human` — approve each stage
- Invoke a single stage: ask for the subagent by name, e.g.
  "Use the platform-architect subagent to design the infra."

## Handoff contract
Every handoff conforms to `shared/schemas/handoff.schema.json`. The
`gate-check.sh` hook validates it after each stage.
