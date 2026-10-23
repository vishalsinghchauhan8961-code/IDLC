"""Builds the IDLC graph. One graph, three coordination modes.

sequential   : linear edges, conditional 'route back on fail'
orchestrated : a router node decides the next stage each hop
human        : same as sequential but interrupts before each stage for approval
"""
from __future__ import annotations
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.memory import MemorySaver
from .state import IDLCState
from .agents import run_stage, NEXT

STAGES = ["ui", "platform", "app", "security", "qa"]
MAX_ATTEMPTS = 2  # loop guard: escalate to human after this many retries


def _gate_router(state: IDLCState):
    """Conditional edge: read the last handoff and decide where to go."""
    h = state["handoffs"][-1]
    stage = h["stage"]
    status = h["status"]
    attempts = state.get("attempts", {}).get(stage, 0)

    if status == "needs_human_review":
        return "human_review"
    if status == "failed":
        if attempts >= MAX_ATTEMPTS:
            return "human_review"          # too many retries -> escalate
        # route back to the consumer named for a fix, else re-run this stage
        return h.get("consumer") or stage
    # passed
    nxt = NEXT[stage]
    return nxt if nxt else END


def _human_review(state: IDLCState):
    """Terminal-ish node; interrupt lands here for human decision."""
    return {}


def build_graph(mode: str):
    g = StateGraph(IDLCState)
    for s in STAGES:
        g.add_node(s, run_stage(s))
    g.add_node("human_review", _human_review)

    g.add_edge(START, "ui")

    if mode == "orchestrated":
        # every stage flows through the gate router which picks the next node
        for s in STAGES:
            g.add_conditional_edges(s, _gate_router,
                                    {**{x: x for x in STAGES},
                                     "human_review": "human_review", END: END})
    else:
        # sequential + human share linear happy-path with fail-routing
        for s in STAGES:
            g.add_conditional_edges(s, _gate_router,
                                    {**{x: x for x in STAGES},
                                     "human_review": "human_review", END: END})
    g.add_edge("human_review", END)

    checkpointer = MemorySaver()
    if mode == "human":
        # pause before each specialist stage so a human can approve/deny
        return g.compile(checkpointer=checkpointer,
                         interrupt_before=STAGES)
    return g.compile(checkpointer=checkpointer)
