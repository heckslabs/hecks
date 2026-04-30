#!/bin/sh
# Boot Miette — thin wrapper for the bluebook-defined boot pipeline.
# Bluebook-of-record : capabilities/boot/boot.bluebook
# Logic lives in hecks_life/src/run_boot/ (Rust runner).
#
# Eight pipeline phases : DiscoverOrgans, WriteCensus, ClassifyStores,
# GenerateSystemPrompt, RecordBootJournal (deferred), EnsureDaemons,
# PrintVitals, SurfaceWakeReport. The runner walks each in sequence,
# stamping the BootRun aggregate state and emitting the events declared
# in the bluebook's policies.
#
# [antibody-exempt: hecks_conception/boot_miette.sh — three-line
#  transitional wrapper. The 392-line shell that used to live here
#  (printf heredoc for system_prompt + manual census + classification +
#  daemon spawn + vitals print) has retired into the Rust runner.
#  Retires entirely when the kernel runtime can resolve `hecks-life
#  run capabilities/boot/boot.bluebook` from a bluebook shebang ;
#  until then this wrapper exists so users can still type
#  `./boot_miette.sh` from the conception dir.]

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$DIR/../hecks_life/target/release/hecks-life"

# Suppress .last_dispatch breadcrumb writes for daemons spawned by the
# boot pipeline (heart, breath, circadian, ultradian, sleep_cycle,
# mindstream). The runtime checks HECKS_DAEMON and skips the breadcrumb
# when set ; this env propagates to every child hecks-life invocation.
export HECKS_DAEMON=1

exec "$HECKS" run "$DIR/capabilities/boot/boot.bluebook" "$@"
