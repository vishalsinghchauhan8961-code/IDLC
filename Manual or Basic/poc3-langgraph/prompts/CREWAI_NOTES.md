# CrewAI shape (for comparison)

CrewAI models this as a Crew of Agents with sequential (or hierarchical) Process:

    from crewai import Agent, Task, Crew, Process
    ui = Agent(role="UI Designer", goal="...", backstory="...")
    platform = Agent(role="Platform Architect", ...)
    # one Task per stage, context=[previous_task]
    crew = Crew(agents=[ui, platform, ...], tasks=[...],
                process=Process.sequential)   # or Process.hierarchical + manager_llm

## Where CrewAI is weaker for IDLC
- Gate-based *route-back-on-fail* isn't first-class; you emulate it with a
  manager agent (hierarchical) or by re-running tasks, losing the clean
  conditional-edge semantics LangGraph gives you.
- Human-in-the-loop exists (human_input=True on a Task) but is coarser than
  LangGraph's interrupt_before with checkpoint resume.

## Where CrewAI is nicer
- Less boilerplate for the pure sequential happy path.
- Role/goal/backstory framing maps 1:1 to the IDLC personas.
