# IDLC — Hybrid POC (Platform 4): Claude Code as the brain

Claude Code is the ORCHESTRATOR. Individual IDLC stages are dispatched to
whichever engine is best for that stage:

  ui        -> Claude Code subagent (fast iteration on design)
  platform  -> Claude Code subagent (architecture reasoning) + Terraform
  app       -> GitHub Copilot coding agent (via Azure DevOps adapter)
  security  -> Claude Code subagent (audit reasoning)
  qa        -> Azure DevOps pipeline (real test execution in CI)

The brain reads/writes the SAME handoff.json contract, so stages are portable:
you can move any stage between engines by changing one line in routing.yaml.
