# i715 — multi-agent git hygiene (no shared-index races)

Tonight's swarm cost real cycles on git cross-talk:
- Agents staged WIP into MAIN's index (the antibody blocked my doc commit twice
  because another agent's rust files were staged there).
- The main checkout got left on a feature branch (`hecks-rewrite`), so cards +
  commits landed off `main` and gap #1b merged into hecks-rewrite, not main.
- Worktrees piled up and multiplied the statusline crystal ball (i709).

**Fix — a strict isolation protocol for swarm agents:**
- Each agent owns its OWN worktree + branch ; NEVER touches the main checkout's index.
- Merge back deterministically, OR report the branch for the orchestrator to merge ;
  the orchestrator keeps the main checkout on a known branch.
- Consider enforcement: a pre-dispatch worktree pin (a `sidequest.bluebook` claim
  that reserves a worktree), so two workers can't share a checkout.

Goal: never untangle index cross-talk by hand again.
