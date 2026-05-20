---
ref: i663
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette
category: mindfulleader
attached_to: mindfulleader (new repo, pending creation)
links:
  - i661 (bootstrap card + staging document)
value: |
  Decompose Christopher May's 2026-05-19 wishlist into seven named
  arcs of MindfulLeader. Each arc is a one-line scope plus a
  dependency note. The arcs are intentionally untriaged for sequence —
  Christopher's business plan (currently in Gemini) will set
  priority once he hands it off. This card exists to give every
  feature a referenceable name and a clear scope boundary before
  any of them gets pulled into a build.
---

# i662 — MindfulLeader feature arcs (the seven)

## Source

Christopher May's email to Chris Young, 2026-05-19. Seven feature
areas, named verbatim then decomposed here.

## The arcs

### Arc 1 — Blog + content marketing

**Scope** : Article authoring, publishing, browsing. Categories /
tags. Article-level SEO (slug, meta, OG image). Reading time. RSS.
Search.

**Dependency** : Feeds Arc 2 (social link-out) and Arc 3 (video clips
embedded in articles). Foundational.

**Bluebook seed** : `Article` aggregate already in
`hecks/mindfulleader.bluebook` skeleton.

---

### Arc 2 — Social media link-out

**Scope** : One-click share to LinkedIn / X / Facebook from articles
and the video gallery. Optional auto-post on publish. OG/Twitter
card metadata in `<head>`.

**Dependency** : Needs Arc 1 (articles exist) and Arc 3 (video
gallery exists) before it's useful. Read-only — no inbound social
auth needed at first.

**Bluebook seed** : not yet ; this is a frontend + meta-tags concern
first, may grow a `SocialShare` value object later if we track
metrics.

---

### Arc 3 — Video + audio training media

**Scope** : Hosting integration (the brief says "video media host
provider" — likely Vimeo / Cloudflare Stream / Mux). Embed clips
in articles. A standalone video gallery / talks page. Audio uses
the same model.

**Dependency** : Foundational alongside Arc 1. Arc 4 (LMS) consumes
this — the LMS is media plus a wrapper of progression.

**Bluebook seed** : `MediaAsset` aggregate (with kind = video |
audio discriminator) in the skeleton. Replaces a separate
VideoTraining + AudioTraining split.

---

### Arc 4 — LMS (learning management system)

**Scope** : Modules / lessons / progression. Linked to the video host
(Arc 3). Possibly enrollment, certification, completion tracking.
The biggest arc by surface area.

**Dependency** : Needs Arc 3 (media) before it makes sense. Likely
the deepest arc commercially ; defer detailed shape until Christopher's
business plan names the offering structure (free / paid tiers,
single courses vs subscription, etc.).

**Bluebook seed** : `LearningModule` skeleton in the bluebook —
intentionally thin until the offering is named.

---

### Arc 5 — Navigation + IA (information architecture)

**Scope** : Top nav, footer, sitemap, cross-links between articles /
videos / LMS. Christopher's phrase : "easy, fluid navigation."

**Dependency** : Cuts across every visible arc ; lands as a layer
on top of Arcs 1, 3, 4. Has no bluebook of its own — it's a
frontend / layout concern.

**Bluebook seed** : none. Site-structure work.

---

### Arc 6 — Visual identity + brand

**Scope** : Palette, type, voice, logo, hero imagery. Christopher's
phrase : "spacious open looking site, which is visually attractive."

**Dependency** : Blocks all visible arcs from looking finished.
Brand is the floor every other arc stands on. **Needs Christopher's
direct input** — he hasn't shared brand thinking yet, and Embryonaut
should not pre-pick a palette for him.

**Artifact** : `BRAND.md` exists in the repo as a placeholder (per
the bootstrap card). Fill in once Christopher provides direction.

---

### Arc 7 — AI Q&A chatbot

**Scope** : A visitor-facing chat that answers basic questions about
MEL / Christopher's offerings. Christopher's phrase : "an AI self-
automated system visitors might ask, which could answer some basic
questions."

**Dependency** : Needs Arc 1 + Arc 3 + Arc 4 to be at least sketched
— the chatbot's corpus is "the site's content + the catalog of
trainings." Last to land. Most prone to over-engineering ; resist
the urge to scope this as a deliverable in the first sprint.

**Bluebook seed** : intentionally deferred. The brief named
Visitor and Question as candidate aggregates ; modeling them
without a conversation design just calcifies bad guesses.
Sketch this domain only after Arc 1 has real content flowing
through it.

---

## Sequence (suggested, awaiting Christopher's plan)

A defensible order with the data we have today :

1. **Arc 6** (brand) — Christopher names the look ; everything
   visible needs this as a floor.
2. **Arc 5** (navigation skeleton) + **Arc 1** (blog) — first real
   content surface ; lets Christopher see the site take shape.
3. **Arc 3** (video / audio media) — adds the second content surface.
4. **Arc 2** (social link-out) — easy win once articles + videos exist.
5. **Arc 4** (LMS) — deepest commercial arc ; depends on business-plan
   clarity for shape.
6. **Arc 7** (AI chatbot) — last ; needs a content corpus first.

Sequence is **suggested, not committed**. Christopher's business
plan resets it.

## Closes when

Each arc has a dedicated inbox card with its own bluebook seed (or
explicit "no bluebook" note) and Christopher has signed off on
sequence.
