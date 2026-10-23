# Azure DevOps adapter (app + qa stages)
Trigger:  az pipelines run --name idlc-app --parameters mode=orchestrated
Poll:     az pipelines runs show --id <id>  (until state=completed)
Collect:  az pipelines runs artifact download --artifact-name handoff-app
Place downloaded handoff at handoffs/app.json for the brain to read.
