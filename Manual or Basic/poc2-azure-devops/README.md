# IDLC — Azure DevOps + GitHub Copilot POC (Platform 2)

This POC mirrors Image 2 most literally: the "agents" are GitHub Copilot
coding agents + custom chat modes, coordinated by Azure DevOps Pipelines that
act as the gate/handoff engine. The pipeline stages ARE the IDLC stages.

## Coordination mapping
- sequential  -> pipeline `dependsOn` chain (each stage waits for the prior)
- orchestrated-> a control stage reads handoff.json and sets pipeline variables
                 that conditionally trigger downstream stages
- human       -> ManualValidation task (approval gate) before each stage

## The agents
Copilot "custom chat modes" (.github/copilot/*.chatmode.md) give each IDLC role
its own persona + tool scope, matching the per-agent tool tables in Image 2.
