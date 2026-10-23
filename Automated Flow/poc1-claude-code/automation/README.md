# POC 1 — Automated runs (work item → agent → PR)

This turns POC 1 from a manual `/idlc-run` you type by hand into an
event-driven pipeline: **update a work item → a pipeline fires → Claude Code
runs headless → the agents open a PR, set the work item state, and comment.**

## The three moving parts (and which of your questions each answers)

| Piece | File | Answers |
|---|---|---|
| Trigger | `automation/idlc-auto.yml` + an ADO Service Hook | "run on work item update" |
| Requirement source | `scripts/bootstrap_from_workitem.py` | "no more manual spec folder" |
| Write-backs | `.claude/agents/idlc-reporter.md` (via MCP) | "auto PR, state, comments" |

## What MCP is (and isn't) here

MCP is the agent's **outbound arm** — how Claude, *while running*, reads a work
item, opens a PR, sets state, posts a comment. It is configured in `.mcp.json`.

MCP is **not** a trigger. It never starts a run. Starting a run from a work-item
change is a separate inbound mechanism (the Service Hook + pipeline below).
Think: MCP = the agent's hands while it works; the Service Hook = the doorbell
that wakes it up. You need both.

## Setup

### 1. Secrets
Create an Azure DevOps variable group named `idlc-secrets` (Pipelines →
Library) with: `ANTHROPIC_API_KEY`, `ADO_PAT`, `GITHUB_TOKEN`. The PAT needs
Work Items (read/write) and Code (read/write, to open PRs).

### 2. Register the pipeline
Add `automation/idlc-auto.yml` as a new pipeline. It has `trigger: none` — it
only runs when the Service Hook calls it.

### 3. Create the Service Hook (the actual trigger)
Project Settings → Service Hooks → **+** →
- Trigger: **Work item updated**
- Filter: your Area Path, and — strongly recommended — a field condition so it
  only fires when you deliberately opt a work item in. e.g. only when
  **State changes to "Ready for Agent"** (add that state, or reuse a tag).
  Without a filter it fires on *every* edit, which you don't want.
- Action: **Trigger Azure Pipeline** → select this pipeline → map the work
  item id into the variable `WORKITEM_ID`.

### 4. Headless settings
The pipeline points Claude Code at `automation/settings.automation.json`, which
allows the agent to push its **own feature branch** (needed so the reporter can
open a PR). It still denies push to `main`, `terraform apply`, force-push, and
`rm -rf`. The default `.claude/settings.json` stays stricter for local
interactive use — don't use the automation settings on your laptop.

## The flow, end to end

    Work item state -> "Ready for Agent"
        │  (Service Hook)
        ▼
    Pipeline: idlc-auto.yml
        │  bootstrap_from_workitem.py  →  docs/specs/product-spec.md
        │  git checkout -b feature/wi-<id>
        ▼
    claude -p "/idlc-run sequential ..."   (headless)
        │  ui → platform → app → security → qa
        ▼
    idlc-reporter (MCP):
        ├─ open PR  feature/wi-<id> → main   (never merges)
        ├─ set work item state → In Review / Blocked / Needs Input
        └─ comment: per-stage summary + PR link

## Try one piece locally first

The requirement-from-work-item step runs standalone, so you can prove that half
without the full pipeline:

    export ADO_ORG=yourorg ADO_PROJECT=yourproject ADO_PAT=xxxx
    python3 scripts/bootstrap_from_workitem.py --id 4821 --out /tmp/spec.md
    cat /tmp/spec.md

If that produces a clean spec from your real work item, the trigger half is
just wiring.

## Honest caveats

- **Unattended agents need guardrails.** Headless runs use
  `--dangerously-skip-permissions`, so the deny-list in the automation settings
  is your safety net, not a live human. Keep it tight. Start with the pipeline
  only allowed to run on a hand-picked "Ready for Agent" state so nothing fires
  by accident.
- **Cost.** Every trigger is a full agent run (API tokens + a CI agent). Filter
  hard so only intended work items fire it.
- **This is still human-gated where it matters.** The agent opens a PR; a person
  reviews and merges. It sets state to "In Review", not "Done". The automation
  removes the typing, not the judgment.
- **Model/tool names drift.** Verify current Claude Code flags
  (`--dangerously-skip-permissions`, headless `-p`) and MCP server package names
  against the docs before relying on them; they change.
