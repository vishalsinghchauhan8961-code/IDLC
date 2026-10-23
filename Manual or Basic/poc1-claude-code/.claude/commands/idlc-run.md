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

Start by confirming a product spec exists at docs/specs/product-spec.md.
If it doesn't, help me write one first.
