"""Shared state passed along the IDLC graph."""
from __future__ import annotations
from typing import TypedDict, Literal, Optional
from operator import add
from typing import Annotated

Stage = Literal["ui", "platform", "app", "security", "qa"]
Status = Literal["passed", "failed", "needs_human_review"]


class Handoff(TypedDict):
    stage: Stage
    producer: str
    consumer: Optional[str]
    status: Status
    artifacts: list[dict]
    gate: dict
    open_questions: list[str]
    timestamp: str


class IDLCState(TypedDict):
    product_spec: str
    mode: Literal["sequential", "orchestrated", "human"]
    current_stage: Stage
    # append-only log of every handoff produced
    handoffs: Annotated[list[Handoff], add]
    # how many times each stage has run (loop guard)
    attempts: dict
    done: bool
