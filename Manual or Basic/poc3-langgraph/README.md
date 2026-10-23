# IDLC — LangGraph POC (Platform 3)

A runnable graph implementation of the IDLC pipeline with all three
coordination modes. LangGraph is chosen over CrewAI because the gate/approval
routing is naturally a state graph with conditional edges and interrupts.

## Why LangGraph (vs CrewAI)
- Gates = conditional edges. Failure routing = edges back to prior nodes.
- Human-in-the-loop = `interrupt_before` on a node. CrewAI can do sequential
  crews but expressing "on fail, route back to stage X, else advance" is
  clumsier there. See prompts/CREWAI_NOTES.md for the CrewAI shape.

## Run
    pip install -r requirements.txt
    export ANTHROPIC_API_KEY=...
    python -m idlc.run --mode sequential
    python -m idlc.run --mode orchestrated
    python -m idlc.run --mode human   # pauses at each gate
