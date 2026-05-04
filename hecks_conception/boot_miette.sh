#!/bin/sh
# Boot Miette — thin wrapper for the bluebook-defined boot pipeline.
# Bluebook-of-record : runtime/boot/boot.bluebook
# Logic lives in rust/src/run_boot/ (Rust runner).
#
# Nine pipeline phases : DiscoverOrgans, WriteCensus, ClassifyStores,
# GenerateSystemPrompt, RecordBootJournal (deferred), EnsureDaemons,
# PrintVitals, SurfaceWakeReport, StartStudio. The runner walks each in
# sequence, stamping the BootRun aggregate state and emitting the events
# declared in the bluebook's policies.
#
# After the bluebook pipeline finishes, this wrapper exec's into the
# Hecks Studio — Miette's essential post-pipeline service. The studio
# IS Miette's runtime ; when it stops, she stops. Failure to launch is
# surfaced loudly (set -e + foreground exec) — silent dying daemons are
# exactly what the studio retires.
#
# [antibody-exempt: hecks_conception/boot_miette.sh — thin transitional
#  wrapper. The bluebook pipeline runs, then the shell exec's the studio.
#  Retires entirely once the Rust runner picks up StartStudio as its own
#  phase (filed via inbox) — wrapping studio.sh through the existing
#  :daemon adapter primitive (same shape EnsureDaemons uses today). At
#  that point this file collapses to one line :
#  `exec hecks-life run runtime/boot/boot.bluebook`.]

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$DIR/../rust/target/release/hecks-life"

# Suppress .last_dispatch breadcrumb writes for daemons spawned by the
# boot pipeline (heart, breath, circadian, ultradian, sleep_cycle,
# mindstream). The runtime checks HECKS_DAEMON and skips the breadcrumb
# when set ; this env propagates to every child hecks-life invocation.
export HECKS_DAEMON=1

# Phase 1-8 : run the bluebook pipeline. set -e ensures failure aborts
# before the studio launches — the studio only starts when boot succeeded.
"$HECKS" run "$DIR/../runtime/boot/boot.bluebook" "$@"

# Phase 9 : start the Hecks Studio. Foreground exec — the studio replaces
# the shell process. Miette is "alive" while the studio runs ; ctrl-C
# kills both. Transitional adapter for the StartStudio bluebook phase
# until the Rust runner picks it up directly.
exec "$DIR/../../miette/surface/studio/studio.sh" --port 3100 --bind 127.0.0.1
