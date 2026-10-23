# IDLC Agent Team — System Design

Building an AI agent team that runs the **Intelligent-Driven Life Cycle** from Image 2 (Leadership → UI → Architecture → App → Security → QA), implemented four ways.

---

## 1. What we're actually building

Image 2 is a **sequential handoff pipeline with quality gates**. Human roles (Justin/Damien, Maya, Ben, Carl) each own a stage and hand a concrete artifact to a specialized agent (A/B/C/C.2/D). The agents are not chatting in parallel — each one *consumes the previous stage's output and produces the next stage's input*.

The single most important design decision falls out of that observation: **the contract between stages matters more than the agents themselves.** If every stage emits the same well-defined handoff artifact, you can swap the engine running any stage without touching the others. That is exactly what lets us build the same system on four platforms and even mix them (POC 4).

So the architecture has two invariant pieces and one variable piece:

- **Invariant — the handoff contract** (`shared/schemas/handoff.schema.json`): what a stage must produce to be considered done.
- **Invariant — the agent prompts** (`shared/prompts/*.md`): the role, inputs, outputs, and self-gate for each of the five agents. Identical across all POCs.
- **Variable — the orchestration engine**: what reads a handoff, decides who runs next, and enforces the gate. This is the only thing that differs between platforms.

---

## 2. The handoff contract (the spine)

Every stage emits a `handoff.json`:

| Field | Purpose |
|---|---|
| `stage` | which IDLC stage produced this |
| `producer` / `consumer` | who made it, who consumes it next |
| `status` | `passed` \| `failed` \| `needs_human_review` — the gate result |
| `artifacts[]` | concrete files produced (spec, design, adr, iac, code, test, report) |
| `gate.checks[]` + `gate.score` | evidence the orchestrator uses to route |
| `open_questions[]` | blocking questions; non-empty ⇒ pause for a human |

**The rule the whole system runs on:** *an agent must not start its stage unless the upstream handoff `status == "passed"`.* Everything else — sequential chaining, orchestrator routing, human approval — is just different ways of enforcing and reacting to that rule.

---

## 3. The five agents (mapped from Image 2)

| IDLC agent | Our agent | Consumes | Produces | Gate (self-check) |
|---|---|---|---|---|
| Agent A (UI) | `ui-designer` | product spec | UI spec, design tokens, component contracts | every screen has empty/loading/error states; every component lists its data fields |
| Agent B (Platform) | `platform-architect` | UI spec + component contracts | ADR, Terraform, OpenAPI contract | `terraform validate` passes; OpenAPI covers every UI data field; secrets via Key Vault |
| Agent C (App) | `app-engineer` | OpenAPI + component contracts | Functions, Angular, SQL | builds clean; every OpenAPI path implemented; no hardcoded secrets |
| Agent C.2 (Security) | `security-auditor` | app source | audit report | no secrets; authz on every endpoint; per-device IoT identity; no critical CVEs |
| Agent D (QA) | `qa-analyst` | running app + spec | tests, test report | every acceptance criterion has a test; contract tests pass |

Security (C.2) is deliberately a **gate, not a builder** — it can only pass work forward or bounce it back to `app-engineer`. That models the "Agent C.2 (Security)" box hanging off Agent C in Image 2.

The reference app the team builds is a **device-telemetry slice** (device list, live sensor chart, alerts) on your real stack — Azure Functions, IoT Hub, Azure SQL, Angular — so the POC exercises the same shapes as your day-to-day work rather than a toy.

---

## 4. The three coordination modes (they compose)

These are layers on the same graph, not three separate designs. You pick one at run time.

### Mode 1 — Sequential
Linear chain. Each agent runs, emits a handoff; if `passed`, the next agent runs. If `failed`, control routes back to the stage named in the handoff. Simplest; best default. The failure edge is what makes it more than a dumb pipe.

### Mode 2 — Orchestrated
A dedicated **orchestrator agent** sits above the specialists. After every stage it reads the handoff, validates it, and *decides* who runs next — including sending work back, re-running a stage, or escalating. Use this when routing logic gets richer than "next in line" (e.g. security bounces to app, app re-derives against a revised contract, platform gets pulled back in). Costs an extra reasoning hop per stage.

### Mode 3 — Human-in-the-loop
Same chain, but the pipeline **pauses at each gate** and waits for your explicit approval before the next stage runs. This is the `needs_human_review` path plus a hard stop at every boundary. Use it early, when you don't yet trust the agents, then graduate to sequential.

**How they relate:** sequential is the base graph; orchestrated swaps the "pick next stage" decision from a static edge to an agent; human adds an interrupt before each node. All three read and write the identical handoff contract, so you can run UI in human mode and everything after in sequential if you want.

---

## 5. The four platform POCs

Each POC is a self-contained folder you can drop in and run. They share `shared/`.

### POC 1 — Claude Code (subagents + MCP)
`.claude/agents/*.md` are the five specialists plus an `idlc-orchestrator`. `.mcp.json` wires GitHub + Azure DevOps. A `SubagentStop` hook (`gate-check.sh`) validates each handoff against the schema and blocks on failure. `/idlc-run [mode]` drives the pipeline.

- **Strengths:** least infrastructure; agent definitions are plain Markdown; the gate hook enforces the contract automatically; MCP gives real GitHub/ADO access.
- **Best for:** fast iteration, a single developer or small team, reasoning-heavy stages.
- **Watch out:** orchestration lives partly in prose (the slash command), so complex routing is less rigid than code.

### POC 2 — Azure DevOps + GitHub Copilot
Mirrors Image 2 most literally. The **pipeline stages ARE the IDLC stages.** Copilot custom chat modes (`.github/copilot/*.chatmode.md`) give each agent its persona and tool scope. The pipeline's `dependsOn` chain is sequential mode; conditional stage triggers are orchestrated mode; `ManualValidation@0` tasks are human mode. Gates are pipeline jobs that validate the handoff and set an output variable that downstream stages condition on.

- **Strengths:** real CI/CD, real approvals, real audit trail; matches the tools already in Image 2; QA actually executes in CI.
- **Best for:** an org already on Azure DevOps that wants governance and traceability.
- **Watch out:** heaviest to set up; the Copilot coding-agent invocation (`invoke-copilot.sh`) is the piece you wire to your tenant; slower feedback loop.

### POC 3 — LangGraph (custom framework)
A **runnable** Python graph. Stages are nodes; gates are conditional edges; failure-routing is edges back to prior nodes; human mode is `interrupt_before` with checkpoint resume. All three coordination modes come from one `build_graph(mode)`. Uses the *same* `shared/prompts` the other POCs use. `CREWAI_NOTES.md` shows the CrewAI shape and where it's weaker (gate route-back and fine-grained human interrupts).

- **Strengths:** most control and testability; routing logic is explicit code, not prose; easy to unit-test the state machine; portable off any single vendor.
- **Best for:** when you need custom routing, retries, budgets, or to embed the pipeline inside a larger service.
- **Watch out:** you own the plumbing (retries, observability, cost tracking) that the managed platforms give you.

### POC 4 — Hybrid (Claude Code as the brain)
Claude Code orchestrates, but each stage is dispatched to the **best engine for that stage** via `routing.yaml`: UI/platform/security run as Claude Code subagents (reasoning-heavy), while app and QA run on Azure DevOps pipelines (real build + test execution in CI). Because every engine reads/writes the same handoff contract, moving a stage between engines is a one-line change.

- **Strengths:** plays to each engine's strength; reasoning on Claude, execution in CI; incremental — start all-Claude, push stages to CI as they mature.
- **Best for:** the realistic end state once you know which stages need real CI and which just need good reasoning.
- **Watch out:** two systems to operate; the adapter layer (`adapters/ado_adapter.md`) is the integration surface you maintain.

---

## 6. Recommended path

1. **Start with POC 1 (Claude Code) in `human` mode.** Cheapest way to see the whole pipeline run and to build trust in each agent's output.
2. **Switch POC 1 to `sequential`, then `orchestrated`** as the agents prove out.
3. **Stand up POC 3 (LangGraph) in parallel** if you need custom routing/observability or want vendor independence — it's the most testable.
4. **Adopt POC 4 (Hybrid)** as the target architecture: reasoning stages on Claude Code, app + QA execution on Azure DevOps (POC 2's pipeline), unified by the shared handoff contract.

POC 2 on its own is the right pick only if governance/CI is the priority from day one and you're already all-in on Azure DevOps.

---

## 7. What's real vs. what you wire up

**Real and runnable now:** the handoff schema, all five agent prompts, the Claude Code subagents/hooks/commands, the LangGraph graph (compiles; needs an API key + `pip install`), the ADO pipeline YAML, the hybrid orchestrator.

**Stubs you connect to your environment (clearly marked TODO):** the Copilot coding-agent invocation, the ADO REST trigger/poll/download in the hybrid adapter, and your actual MCP credentials (`GITHUB_TOKEN`, `ADO_PAT`). None of these change the architecture — they're the last-mile connection to your tenant.

The first thing to create in any POC is `docs/specs/product-spec.md` — the Leadership-stage artifact that Agent A consumes. Everything downstream flows from it.
