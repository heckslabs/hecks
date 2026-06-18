# ProcessHealth is hollow — "report a daemon is down" never works (session 5)

Chris : "you say it's mature but I've never seen you report a daemon is down
— you always discover it." Correct. The bluebook is mature ; the BODY is
hollow. Three missing links, all verified 2026-06-17 :

## The three hollow links
1. **The macrophage singleton was never initialized.**
   `storehouse state . ProcessMacrophage process_macrophage` -> `ok:false,
   state:null`. No `StartSession` ever ran ; the `watchlist` (list_of
   ProcessName) is empty. So even a working sweep has nothing to check.
2. **The sweep leaf does not exist.** `process_health.hecksagon`'s
   `RunSweepOnSwept` policy spawns `bin/process_health_sweep` — file MISSING
   (only `process_health_heal.mjs` + `fibroblast_sweep.sh` exist). The 30s
   cadence DOES fire (Procfile:15 `ProcessMacrophage.Sweep --every 30s`),
   emits `Swept`, tries to spawn the missing script, and (likely silently)
   no-ops. The per-sentinel MarkAlive/Hanged/Dead fan-out never happens.
   The lone `process_sentinel.heki` row is malformed : `state:"hanged",
   process_name:[]` (empty) — a stale artifact, never a real check.
3. **No surface.** The statusline (`run_statusline/mod.rs`, kernel-floor)
   renders heart + sleep, NOT any liveness verdict. The body-state line
   tokens (em/md/mel/mi/op/pi/vd) are INBOX-channel counts, not health
   (🩺 md is NOT the doctor). So even a marked-dead sentinel is invisible.

Irony worth surfacing : the health system itself fails silently when its
own sweep leaf is absent — the fail-loudly organ fails quietly.

## Build spec (scope = Chris's literal ask : "report a daemon is DOWN")
Death detection + a visible report. (The CPU/pegged-but-alive dimension —
proven needed by the pulse spin, which a freshness check calls healthy —
is PHASE 2 ; the still-pegged pulse is its ready-made live test.)
1. **Init + watchlist** : dispatch `ProcessMacrophage.StartSession` at boot
   and `Watch` each supervised daemon (heart, breath, voice, pulse,
   restart_prompt, mindstream, … — source from mindstream.fixtures members).
2. **Sweep leaf** (`bin/process_health_sweep`) : THIN impure fact-gatherer
   (same Nirmanakaya glue as heal.mjs). For each watchlist name : pgrep +
   heartbeat/log mtime ; dispatch the EXISTING MarkAlive/MarkHanged/MarkDead.
   NO health logic in the script — thresholds + alive->hanged->dead live in
   the bluebook already.
3. **Surface** : render the WORST sentinel verdict on the statusline
   (kernel-floor Rust, do carefully) — e.g. `💀 voice DOWN` instead of the
   calm heart. Pairs with the existing Heal-with-teeth (overmind restart).

## Acceptance = the kill-test (make the proof the spec)
Stop one daemon (`overmind stop voice` or kill its pid) -> within ~one sweep
(30s) it shows DOWN on the statusline/surface, WITHOUT me discovering it
manually. That single demo converts "mature bluebook" into "actually
protected me."

## Part of the bigger pattern (Chris, session 5)
"Sweep for everything written but not functioning and fix it." ProcessHealth
is instance #1. Siblings already found : awareness (fixed), signal/synapse
consolidation (stubbed), Doctor (unfed). The disease : bluebook-as-design
with no running body — knowledge that isn't exercised by the runtime can't
protect anything.
