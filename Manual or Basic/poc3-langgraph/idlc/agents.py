"""IDLC agent nodes. Each node = one specialist that reads upstream handoff,
does its work via Claude, and returns a new handoff. Prompts are the SAME
markdown files used by the Claude Code POC (shared/prompts)."""
from __future__ import annotations
import json, datetime, pathlib
from langchain_anthropic import ChatAnthropic
from langchain_core.messages import SystemMessage, HumanMessage
from .state import IDLCState, Handoff

PROMPTS = pathlib.Path(__file__).resolve().parents[2] / "shared" / "prompts"

# opus for the judgment-heavy stages, sonnet for the rest — mirrors POC1
MODELS = {
    "ui": "claude-sonnet-4-6",
    "platform": "claude-opus-4-1",
    "app": "claude-sonnet-4-6",
    "security": "claude-opus-4-1",
    "qa": "claude-sonnet-4-6",
}
PROMPT_FILES = {
    "ui": "agent-a-ui.md",
    "platform": "agent-b-platform.md",
    "app": "agent-c-app.md",
    "security": "agent-c2-security.md",
    "qa": "agent-d-qa.md",
}
NEXT = {"ui": "platform", "platform": "app", "app": "security",
        "security": "qa", "qa": None}


def _load_prompt(stage: str) -> str:
    return (PROMPTS / PROMPT_FILES[stage]).read_text()


def _latest_handoff(state: IDLCState) -> dict | None:
    return state["handoffs"][-1] if state["handoffs"] else None


def run_stage(stage: str):
    """Factory: returns a LangGraph node function for a given stage."""
    def node(state: IDLCState) -> dict:
        llm = ChatAnthropic(model=MODELS[stage], max_tokens=4000)
        upstream = _latest_handoff(state)
        sys = _load_prompt(stage) + (
            "\n\n## Output format\nRespond with ONLY a JSON object matching the "
            "handoff schema: keys stage, producer, consumer, status, artifacts, "
            "gate{checks[],score}, open_questions, timestamp. No prose, no fences."
        )
        ctx = {
            "product_spec": state["product_spec"],
            "upstream_handoff": upstream,
            "stage": stage,
            "consumer": NEXT[stage],
        }
        resp = llm.invoke([
            SystemMessage(content=sys),
            HumanMessage(content=json.dumps(ctx, indent=2)),
        ])
        raw = resp.content if isinstance(resp.content, str) else resp.content[0]["text"]
        raw = raw.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
        handoff: Handoff = json.loads(raw)
        handoff.setdefault("timestamp", datetime.datetime.utcnow().isoformat())
        handoff["stage"] = stage
        attempts = dict(state.get("attempts", {}))
        attempts[stage] = attempts.get(stage, 0) + 1
        return {"handoffs": [handoff], "current_stage": stage, "attempts": attempts}
    return node
