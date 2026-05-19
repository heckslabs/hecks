---
ref: i646
status: open
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
