---
ref: i646
status: designed
priority: medium
posted_at: 2026-05-19
posted_by: Miette (Chris: file this one)
category: framework / macrophage / governance
value: 'The macrophage stops being only a checker and becomes a Protector : an aggregate with a real immune interface — Inspect (examine the suspect act/file), CallForHelp (escalate / summon, the cytokine signal), and Destroy (phagocytose : remove the offending artifact). Mirrors real macrophage biology and completes the immune-system metaphor the framework already runs (antibody hook, loc-ratchet, exempt registry).'
---

# i646 - Macrophages become Protectors

## Chris's seed (verbatim)

> macrophages become protectors they have .inspect, .callForHelp, and Destroy.

## Shape (bluebook-first)

Today "macrophage" is a check verb (`storehouse macrophage_check`, the
PostToolUse complaint hook, the bluebook-first immune reminder). The
idea : promote it to a first-class **Protector** aggregate whose
lifecycle is the immune response itself.

- **Inspect** — examine a suspect act / file / diff ; emit an
  assessment (benign | suspect | threat). The non-destructive look.
- **CallForHelp** — the cytokine signal : escalate a suspect finding
  (surface to Chris, open a Violation, summon a sibling check) rather
  than acting alone. The macrophage that knows its limits.
- **Destroy** — phagocytosis : remove / quarantine the offending
  artifact (revert the imperative line, delete the ungoverned script,
  block the commit). The terminal, logged act.

## Why it fits

The framework already runs an immune metaphor (antibody, ratchet,
exempt registry, Governance default-deny). A Protector aggregate with
Inspect / CallForHelp / Destroy makes the metaphor structural instead
of scattered across hooks — each step a governed, bus-emitting command,
so the immune response is itself accountable (ties into Governance :
Governance.Violation could be what CallForHelp records).

## Open questions

- Is Protector a rename/extension of the existing macrophage concept,
  or a new aggregate that the macrophage hook dispatches into?
- Does Destroy require Inspect -> CallForHelp first (a lifecycle
  gate), or can it fire directly on a hard threat?
- Relationship to Governance.EnforcementAdapter (the harness-side
  surface) — Protector is the domain ; EnforcementAdapter the glue?

## Decided 2026-05-19 (Chris, this session) — execution-ready

The macrophage bluebook ratchet (one Macrophage domain, 13 aggregates,
2684 lines, 426 structural units, "13 disconnected concern clusters")
forced this. Per the two-tier ratchet rule (bluebook ratchet → stop &
redesign the domain, not auto-patch), the decided shape is:

1. **Rename `Macrophage` → fold into the existing `Immunity` domain.**
   `aggregates/discipline/immunity/` already uses the sibling-file
   family pattern (`immunity`, `rule`, `violation`, `rename_drift` —
   one `Hecks.bluebook` per file). The 13 macrophage cells join it the
   same way. NOT a single `Hecks.bluebook "Immunity"` split across
   same-named files — that trips `validator_corpus::bare_name_collisions`
   (proven by the two unrelated `Inbox` files). World/boot shape:
   one file = one bluebook, cohesive, in the family directory.

2. **Each macrophage cell = its own bluebook file** in
   `discipline/immunity/`: `bluebook_first`, `fixtures_runtime`,
   `antibody_exemption`, `warnings`, `linear_reference`, `line_count`,
   `test_speed`, `card_lock`, `bidirectional_association`,
   `identity_discipline`, `writing_discipline`,
   `correspondence_discipline`, plus the singleton (`innate`/generic).
   Each ~150-250 lines → file-length ratchet satisfied. Companion
   `.behaviors` split mirrors each.

3. **Each cell becomes a Protector** (i646's core): the per-rule shape
   (StartSession / Check / RecordViolation / Complain / Exempt) gains
   the immune interface — Inspect (non-destructive look →
   benign|suspect|threat), CallForHelp (cytokine: escalate / open a
   Governance.Violation), Destroy (phagocytose: revert/quarantine/
   block, terminal + logged). Answers i646 open-Q1: it IS a
   rename/extension, folded into Immunity, not a parallel aggregate.

4. **Old commands kept alive via redirect storehouse commands.** The
   current dispatch surface (`storehouse macrophage_check`, the
   PostToolUse hook in `bin/macrophage-hook`, `enforce-edit` alias)
   keeps working: add redirect/alias commands that forward the old
   verbs to the new Immunity FQNs. No call-site rewrite in one pass;
   the redirect layer is the compatibility seam (matches `rename_drift`
   which already lives in immunity/ — apt).

## Sequencing (locked)

Focused, committed single pass — NOT inline at session tail. main was
just stabilized through 4 kernel merges + a specializer regen; a
half-migrated immune system on main is unacceptable. Spec is locked
here (decide-API-before-implementing). Execution order: (a) scaffold
the N immunity/ cell bluebooks + behaviors from the monolith's
aggregate blocks, verbatim, one per file ; (b) add the redirect
commands ; (c) delete the monolith ; (d) `storehouse parse` +
`--corpus` validate clean (no bare_name_collisions) ; (e) macrophage
hook smoke ; (f) cargo + full gate ; one commit.

status → designed (execution-ready, awaiting focused-session slot)
