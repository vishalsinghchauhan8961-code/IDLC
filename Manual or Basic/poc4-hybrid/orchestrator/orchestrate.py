"""Hybrid orchestrator. Claude Code is the brain; this driver reads routing.yaml,
runs each stage on its assigned engine, and enforces the shared gate contract.

It shells out to:
  - claude-subagent : `claude -p "use the <agent> subagent ..."` (headless mode)
  - copilot-ado     : triggers an Azure DevOps pipeline via REST, polls, pulls handoff
Both engines must drop handoffs/<stage>.json conforming to the shared schema.
"""
from __future__ import annotations
import json, pathlib, subprocess, sys, time
try:
    import yaml
except ImportError:
    yaml = None

ROOT = pathlib.Path(__file__).resolve().parents[1]
HANDOFFS = ROOT / "handoffs"
ORDER = ["ui", "platform", "app", "security", "qa"]
NEXT = dict(zip(ORDER, ORDER[1:] + [None]))


def load_routing():
    txt = (ROOT / "orchestrator" / "routing.yaml").read_text()
    if yaml:
        return yaml.safe_load(txt)
    raise SystemExit("pip install pyyaml to run the hybrid orchestrator")


def run_claude_subagent(stage, agent, upstream):
    HANDOFFS.mkdir(exist_ok=True)
    prompt = (f"Use the {agent} subagent for the IDLC '{stage}' stage. "
              f"Read the upstream handoff at {upstream or 'docs/specs/product-spec.md'}. "
              f"Write handoffs/{stage}.json per shared/schemas/handoff.schema.json.")
    # headless Claude Code:
    subprocess.run(["claude", "-p", prompt], cwd=ROOT, check=False)
    return HANDOFFS / f"{stage}.json"


def run_copilot_ado(stage, pipeline, upstream):
    # Trigger ADO pipeline via REST (az devops / curl), poll to completion,
    # then download the handoff artifact. Stubbed here.
    print(f"[hybrid] dispatch stage '{stage}' to Azure DevOps pipeline '{pipeline}'")
    print("        (az pipelines run --name ... ; poll ; az pipelines runs artifact download)")
    return HANDOFFS / f"{stage}.json"


def read_handoff(path):
    if not pathlib.Path(path).exists():
        return {"stage": "?", "status": "failed", "gate": {"score": 0}, "consumer": None}
    return json.loads(pathlib.Path(path).read_text())


def dispatch(stage, cfg, upstream):
    if cfg["engine"] == "claude-subagent":
        return run_claude_subagent(stage, cfg["agent"], upstream)
    if cfg["engine"] == "copilot-ado":
        return run_copilot_ado(stage, cfg["pipeline"], upstream)
    raise ValueError(f"unknown engine {cfg['engine']}")


def main():
    routing = load_routing()
    mode = routing.get("mode", "sequential")
    max_attempts = routing.get("max_attempts", 2)
    attempts = {s: 0 for s in ORDER}

    stage = "ui"
    upstream = None
    while stage:
        cfg = routing["stages"][stage]
        attempts[stage] += 1
        print(f"\n=== IDLC stage: {stage} on engine {cfg['engine']} "
              f"(attempt {attempts[stage]}) ===")
        path = dispatch(stage, cfg, upstream)
        h = read_handoff(path)

        if mode == "human":
            if input(f"[GATE] stage '{stage}' status={h['status']}. approve/deny? "
                     ).strip().lower().startswith("d"):
                print("Denied — halting."); return

        if h["status"] == "passed":
            upstream = str(path)
            stage = NEXT[stage]
        elif h["status"] == "needs_human_review":
            print("Needs human review:", h.get("open_questions"))
            return
        else:  # failed
            if attempts[stage] >= max_attempts:
                print(f"Stage '{stage}' failed {attempts[stage]}x — escalating.")
                return
            print(f"Stage '{stage}' failed — retrying / routing back.")
            stage = h.get("consumer") or stage
    print("\n=== IDLC pipeline complete ===")


if __name__ == "__main__":
    main()
