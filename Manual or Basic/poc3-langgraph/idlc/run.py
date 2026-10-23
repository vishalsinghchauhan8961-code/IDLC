"""CLI: python -m idlc.run --mode sequential|orchestrated|human"""
from __future__ import annotations
import argparse, json, pathlib, uuid
from .graph import build_graph

SPEC = pathlib.Path("docs/specs/product-spec.md")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="sequential",
                    choices=["sequential", "orchestrated", "human"])
    ap.add_argument("--spec", default=str(SPEC))
    args = ap.parse_args()

    spec_text = pathlib.Path(args.spec).read_text() if pathlib.Path(args.spec).exists() \
        else "Build a device-telemetry dashboard: device list, live sensor chart, alerts."

    app = build_graph(args.mode)
    init = {"product_spec": spec_text, "mode": args.mode,
            "current_stage": "ui", "handoffs": [], "attempts": {}, "done": False}
    cfg = {"configurable": {"thread_id": str(uuid.uuid4())}}

    if args.mode == "human":
        # step through interrupts, asking for approval at each gate
        state = init
        for _ in range(20):
            for event in app.stream(state, cfg):
                pass
            snap = app.get_state(cfg)
            if not snap.next:            # graph finished
                break
            nxt = snap.next[0]
            ans = input(f"\n[GATE] About to run stage '{nxt}'. approve/deny? ")
            if ans.strip().lower().startswith("d"):
                print("Denied. Halting pipeline.")
                return
            state = None                 # resume from checkpoint
        _dump(app.get_state(cfg).values)
    else:
        final = app.invoke(init, cfg)
        _dump(final)


def _dump(state):
    print("\n=== IDLC RUN COMPLETE ===")
    for h in state.get("handoffs", []):
        print(f"  {h['stage']:9s} -> status={h['status']:18s} "
              f"score={h.get('gate', {}).get('score', '?')}")


if __name__ == "__main__":
    main()
