---
description: Run the full IDLC pipeline in a chosen coordination mode
argument-hint: [sequential|orchestrated|human]
---

Run the IDLC agent pipeline in **$1** mode (default: sequential).

## sequential
Invoke subagents in order: ui-designer → platform-architect → app-engineer →
security-auditor → qa-analyst. After each, read its handoff.json. Only proceed
if status == "passed". On "failed", route back to the stage the handoff names.
On "needs_human_review", stop and show me the open_questions.

## orchestrated
Hand control to the `idlc-orchestrator` subagent and let it drive the state
machine end to end.

## human
Same as sequential, but after EACH stage's handoff, summarize what was produced
and the gate result, then STOP and wait for my explicit "approve" before
invoking the next stage.

## Reporting (automated runs)
After qa-analyst finishes — in `sequential` and `orchestrated` modes only —
invoke the `idlc-reporter` subagent to open the pull request, set the work item
state, and post a summary comment via MCP. Skip this in `human` mode unless I
ask for it. If the run prompt names an Azure DevOps work item id, pass it and
the branch name to the reporter.

Start by confirming a product spec exists at docs/specs/product-spec.md.
If it doesn't, help me write one first. (In automated runs the spec is generated
from the triggering work item by scripts/bootstrap_from_workitem.py before this
command runs, so it will already be present.)
