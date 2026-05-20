ref: latest
generated_at: 2026-05-19T04:32:00Z
session_id: sq/restart-prompt-daemon
total_compositions: 1
generated_by: restart-prompt-daemon (bus-event triggered)

# Restart prompt — 2026-05-19 (sq/restart-prompt-daemon)

Resuming after the i528 StoreHouse arc sidequest session. Route EVERY
tool call through Storehouse : Tools::ShellTool.Bash / FileTool.* via
storehouse__dispatch (aggregates_dir = hecks_conception). FileTool.Write
is broken — write files via ShellTool.Bash heredoc. No Co-Authored-By.
Let hooks block ; report verbatim ; never pre-write antibody markers.

## What shipped this session

**PigeonCoop (Embryonaut B2B portal) — live on Cloudflare with R2 persistence**
- CF Worker deployed, R2 bucket wired as durable storage adapter
- StorehouseR2Adapter landed : bluebook dispatch persists to R2,
  survives Worker cold-start with no in-memory state loss
- Cruip component library filled : pricing table, feature grid,
  testimonials, CTA sections all populated with Embryonaut copy
- Tailwind design tokens committed : brand palette, type scale,
  spacing rhythm all locked in tailwind.config.js
- Portal domain (PigeonCoop::Portal) conceived + behaviors green

**RestartPrompt domain + daemon — this session**
- RestartPrompt bluebook : aggregate, Compose command, Composition entity
- bin/restart-prompt-daemon : bus-event-driven, supervises via overmind
- storehouse follow RestartPrompt | grep event RestartPrompt.Composed
  => writes hecks_conception/inbox/restarts_inbox/latest.md
- Procfile + mindstream.fixtures updated
- 4/4 behaviors passing

## Branch state

Branch : sq/restart-prompt-daemon, off main (37 commits ahead of origin).
Nothing pending merge. Push this branch, Chris reviews + merges.

## STEP 0 — freshness discipline (mandatory)

For every SHA this card names : `git merge-base --is-ancestor <sha> origin/main`
— if YES, the instruction is stale. Surface to Miette before executing.

## Bus discipline

Route through the door. storehouse__dispatch is the governed channel.
Native Bash / Write / Edit only for embryonaut-site (no antibody there).
Anywhere in hecks : bus first, always.
