# lib/hecks_specializer.rb
#
# Hecks::Specializer — i51 Futamura specializer driver
#
# Single entry point for every specializer target. Loads the target's
# shape fixtures via `hecks-life dump-fixtures`, dispatches to the
# target module's #emit, returns the Rust source.
#
# Replaces the Phase A/B per-target bin/specialize-* scripts. The
# common machinery (fixture loading, CLI, diff) lives here; each
# target module holds its emission logic.
#
# Target modules discovered at load-time from lib/hecks_specializer/*.rb.
# Each module must define:
#   REPO_ROOT, SHAPE, TARGET_RS — as module constants
#   class-level #emit -> String — returns the Rust source
# (Convention, not a formal contract yet — Phase C will lift the
# contract into a bluebook too.)
#
# Usage from Ruby:
#   require "hecks_specializer"
#   rust = Hecks::Specializer.emit(:validator)
#
# Usage from CLI (bin/specialize):
#   bin/specialize validator
#   bin/specialize validator --diff
#   bin/specialize dump --output hecks_life/src/dump.rs
