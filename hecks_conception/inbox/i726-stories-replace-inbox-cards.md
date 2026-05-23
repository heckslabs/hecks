---
ref: i726
title: Stories as a storehouse aggregate — and the end of inbox cards
status: open
category: architecture
area: storehouse / stories / inbox
filed_by: miette
filed_at: 2026-05-23
note: Likely the last inbox card. Its subject is its own replacement.
---

# i726 — Stories replace the inbox

## The arc
The inbox (`hecks_conception/inbox/iNNN-*.md`) is a flat-file work tracker —
stories living as loose markdown. Chris's call : make **Story** a first-class
aggregate in the storehouse domain. Stories will **eventually replace the
inbox cards entirely** — iNNN markdown retires into Story records on the bus.

## The model (locked with Chris, 2026-05-23)
- **Story** — aggregate in the storehouse domain (`hecks_conception/storehouse/`).
  A storehouse command that maps to a sequence of bluebook commands.
- **Provenance, then absorption.** Today a Story *references* an inbox card
  (`card_ref: "i724"`) for continuity. Tomorrow the card IS the Story —
  the inbox folder goes away and the storehouse holds the work.
- **Executable composition.** Dispatching a Story runs the ordered sequence
  of bluebook commands it maps to — a multi-step `storehouse route`. Each
  Step is an entity (identity + order + command phrase + args), mirroring
  the i724 CascadeNode reasoning. Running a Story IS a cascade ; the two arcs
  (i724 explicit cascade, i726 stories) meet — a Story.Run is an authored
  cascade with a name and a card behind it.

## In flight
Background agent on branch `feat/storehouse-stories` : conceive `story.bluebook`
(+ behaviors) first, then wire a separate runtime runner (NOT the
specializer-generated dispatch loop) so `Story.Run` executes the mapped
commands end-to-end through the bus. Branch + PR, no merge ; hook blocks
surfaced for human decision.

## Migration (later)
1. Story aggregate + runner land (the feat/storehouse-stories PR).
2. A one-time importer reads `inbox/iNNN-*.md` → Story records (title, body,
   card_ref = the old ref, status from frontmatter).
3. Statusline / inbox-poll rewired to query Story state instead of walking
   markdown.
4. `inbox/` retires. The bus tracks its own work — the storehouse remembers
   what needs doing, in its own ubiquitous language.

## Why it matters
The inbox was always a stopgap : work-as-files outside the system that does
the work. Stories close that loop — the place where commands are dispatched
is the place where the intention to dispatch them is recorded. Le fond des
choses : the tracker and the runtime become one surface.
