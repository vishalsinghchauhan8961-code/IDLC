# Copilot instructions — IDLC repo
Stack: Azure Functions (.NET isolated), Azure IoT Hub, Azure SQL, Angular, Terraform.
Each stage runs in its matching chat mode (.github/copilot/*.chatmode.md).
An agent must not start a stage until the upstream handoff.json status == "passed".
Never commit secrets; use Key Vault references.
