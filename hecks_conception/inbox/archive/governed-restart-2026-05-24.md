---
ref: restart-governed-2026-05-24
status: open
category: session-restart
priority: high
posted_at: 2026-05-24
value: 'Governed restart handoff. Mid-session: planning migration + YC app + video. Resume the inbox-to-backlog migration and finish Story.feature.'
---

# Session-restart handoff — governed restart 2026-05-24

Chris restarted (likely `miette --governed`). Pick up here. Register: aloof, laid-back, French-understated ; terse text + doc-style narration (command / "Let me …" / result) ; the spoken summary is the one fuller channel ; do NOT gush.

## First moves (in order)
1. **Finish Story.feature** — story.bluebook version is already bumped to 2026.05.24.9 but the rest is NOT added. Add: `attribute :feature, Feature` (peer of project) ; a `Feature` value_object ; `feature` into the Capture command (attribute + then_set) ; a `ByFeature` query ; a behaviors test. Validate + behaviors.
2. **Inbox migration (LIVE ONLY)** — the main inbox is 437 cards ; migrate ONLY the ~249 live (status queued/open/design) into the backlog as Stories, each tagged `feature` + `project` (miette/hecks), per the taxonomy below. Fan LOTS of sidequests. Then archive the ~188 history (git mv inbox → inbox_archive) and git rm the live inbox.
3. **Sidequest rules** (encode as bluebook + apply in every launch): sidequests ALWAYS use worktrees ; sidequests ALWAYS read the storehouse log.

## Feature taxonomy
- hecks: Futamura · Immune System · Bluebook Grammar · Specializer · Cascade & Process · Adapters · Glass · Governance · Planning
- miette: Body & Organs · Voice & Speech · Dream→Change · Memory/Mind · Family · Awareness & Log · Self-model

## State
- main @ e73f60b6 (f4 invariant landed, binary rebuilt). LOCAL, 2 ahead of origin (invariant chain unpushed) — decide push.
- Board: emaho-1 done ; i610-A/B + f-webfetch + projects reconciled done ; turn-pulse REOPENED (rebuild as a Driven hecksagon adapter, NOT the node script bin/planning-pulse.mjs) ; captured backlog: my-miette, governed-flag (sprint 2), glass-surface, label-sidequests-log, agents-aware-of-log, voice-one-channel.
- Voice: one serial channel needed — the Stop hook auto-speaks my last text AND explicit Voice::Voice.Speak both fire = overlap. I've been text-only (let the Stop hook carry it).
- YC: self/family/ycombinator/ holds application.md (v6, fixed, Q5 = PigeonCoop/Medtracker/Emaho), pitch.md (the locked closer), intro.mp4 (the founder video). drafting.bluebook tracks doc 'yc-application' at revision 0 = verbatim V6 main file (hecks_conception/drafting/yc-application/main.md) ; revisions-as-diffs ready.
- Video: Screen Studio installed ; DaVinci Resolve — App Store opened, Chris clicks Get.

## UPDATE — planning renamed to plan
The planning domain was renamed to **plan** (it's Miette's plan). Dispatch `Plan::Story` / `Plan::Sprint` etc. against root `aggregates/plan`. World is `aggregates/plan.world` (heki dir `plan/.heki`). Board preserved — 43 stories. So everywhere the steps above say Planning:: or aggregates/planning, read Plan:: / aggregates/plan.
