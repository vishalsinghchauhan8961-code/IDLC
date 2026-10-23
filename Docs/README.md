# IDLC Agent Team

An AI agent team implementing the **Intelligent-Driven Life Cycle** pipeline
(UI → Platform → App → Security → QA) with quality gates, built four ways.

## Read first
- `docs/IDLC-DESIGN.md` — the deep design doc (start here)

## Layout
    shared/            # invariant across all POCs
      schemas/         #   handoff.schema.json — the contract between stages
      prompts/         #   the 5 agent role definitions (reused everywhere)
    poc1-claude-code/  # POC 1: Claude Code subagents + MCP + hooks
    poc2-azure-devops/ # POC 2: Azure DevOps pipeline + GitHub Copilot chat modes
    poc3-langgraph/    # POC 3: runnable LangGraph state machine (all 3 modes)
    poc4-hybrid/       # POC 4: Claude Code brain dispatching to CC + ADO

## Coordination modes (available in every POC)
    sequential   | chain with route-back-on-fail
    orchestrated | an orchestrator agent picks the next stage each hop
    human        | pause for approval at each gate

## Quick start per POC
    # POC1: drop poc1-claude-code/ contents into a repo, open Claude Code, run:
    /idlc-run human

    # POC3: runnable now
    cd poc3-langgraph && pip install -r requirements.txt
    export ANTHROPIC_API_KEY=...
    python -m idlc.run --mode sequential

    # POC2: add pipelines/idlc-pipeline.yml as an Azure DevOps pipeline
    # POC4: cd poc4-hybrid && python orchestrator/orchestrate.py
