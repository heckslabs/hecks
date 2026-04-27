---
title: "Hecks Prior Use — five defensive-publication papers"
version: "prior_use/v1-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# Hecks Prior Use

This directory replaces the single monolithic `hecks-v0` paper with five focused
defensive-publication papers. Each targets a distinct audience and a distinct
technical claim. They can be read independently; each carries its own
introduction, related work, and enumerated techniques.

The original `../hecks-v0/hecks-paper.md` remains as a historical artifact —
the canonical snapshot at commit `e33c6672`. The papers in this directory
supersede it for all forward work.

## Why split

The monolith tried to be five papers in one. The result had seams: a
validation reader had to skim autophagy prose they didn't need; a PL reader
had to skim DDD introductions they already knew; the MCP angle — the one that
matters most for this moment — was three paragraphs buried in an evaluation
section. Reframing by audience is the cheapest way to remove the seams and
the best way to protect each technique individually as prior art.

Splitting also solves a timestamp problem. The monolith carried both
*planned-Phase-B* and *shipped-Phase-E* claims, which forced reconciliations
that aged badly. Broken up, each paper lives at its own cadence: the
validation paper is stable and doesn't need to track autophagy; the Futamura
paper tracks the autophagy frontier tightly; the cascade-lockdown paper can
be cited independently of either.

## What the DSL is for, what the papers are for

The DSL is for adoption. A developer writes

```ruby
Hecks.bluebook "Account" do
  aggregate "Account" do
    command "Withdraw" do
      attribute :amount, Integer
    end
  end
end
```

and, three commands later, is running an event-sourced, MCP-exposed,
HTTP-served domain without ever having read Evans. The DSL teaches DDD by
being the path of least resistance; the framework competes with Rails and
Django on *speed*, not with the Evans book on discipline. `hecks new banking`
producing a running domain in under a minute is the fifteen-minute blog demo
equivalent — the shape that actually spreads.

The papers are for *protecting* the ideas while the DSL does the adoption
work. Defensive publication doesn't generate social proof and doesn't need
to. The jobs are different; the artifacts can be different too.

## The five papers

1. **[`01_ddd_validation/paper.md`](01_ddd_validation/paper.md)** — *Compile-time DDD validation with fix suggestions.*
   Twelve rules, every violation carries remediation, build-time rather than
   runtime. Audience: working engineers. Does not invoke Futamura. The
   shortest and most immediately applicable paper.

2. **[`02_mcp_native_domain/paper.md`](02_mcp_native_domain/paper.md)** — *MCP-native domain frameworks.*
   The self-describing-to-agents angle. Tool generation from commands,
   `llms.txt` as a domain manifest, structured errors for programmatic
   recovery. Expanded with an end-to-end banking example showing an agent
   using the MCP server. This is the paper that matters most for this moment.

3. **[`03_futamura_ddd_runtime/paper.md`](03_futamura_ddd_runtime/paper.md)** — *Futamura across a DDD runtime.*
   The L0–L8 factoring, the specialiser-as-capability argument, Phases A
   through E as shipped. PL-venue audience. Submittable. Does not carry
   introductory DDD material.

4. **[`04_cascade_lockdown/paper.md`](04_cascade_lockdown/paper.md)** — *Cascade lockdown as a testing discipline.*
   The event-emission assertion pattern extracted from event-sourced
   frameworks generally. Hecks is the reference implementation but the paper
   makes the pattern portable.

5. **[`05_parity_language_neutrality/paper.md`](05_parity_language_neutrality/paper.md)** — *Parity as language-neutrality pressure.*
   The methodology claim that maintaining a byte-identical cross-language IR
   forces the IR to remain language-neutral, and that language-neutrality is
   what later enables specialisation. Applies beyond Hecks.

## How to read

- **Engineer evaluating Hecks for a Rails-shaped use case.** Start with the
  [README](../../../README.md) and the Pizzas tutorial. Then read Paper 2
  (MCP) and Paper 1 (validation) in that order.
- **PL researcher.** Paper 3 (Futamura) is self-contained; Paper 5 (parity)
  is the closest companion.
- **Testing-discipline audience.** Paper 4 stands alone.
- **Methodologist building a cross-language system.** Paper 5 generalises;
  Paper 3 is a concrete instance.

## Shared conventions

Each paper uses `paper/prior_use-v1-2026-04-24` as its version string and
cites commit `c4a903f3` as its reproduction tag. File references are
repository-relative; the repository root is what the paper is written
against. Where a paper needs to cite another in this collection, the
reference is by filename.

## On the role of this collection

The techniques enumerated across these five papers are placed in the public
record for defensive-publication purposes: whether or not any of them are
pursued commercially elsewhere, they remain available as prior art from the
date of this deposit.
