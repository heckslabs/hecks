
## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** What else can you take out of the system prompt?

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** What else should be wired to your body but isn't?

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** high
**Status:** queued
**Body:** Never touch the system prompt once you are loaded.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Load your personality at boot — who you are, how you speak, what you care about.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Load your standards at boot — conventions, anti-patterns, capability rules.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Load your short-term memory at boot — what happened last session, active seeds, deferred messages.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Load your long-term memory at boot — people, project knowledge, accumulated identity.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Know bluebook format by keeping an index to hecks — not by reading the DSL reference every time.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Know hecksagon format by keeping an index — domain list, aggregate counts, what's in each project.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** normal
**Status:** queued
**Body:** Know world.hec format by keeping an index — client name, brand colors, server config, data paths.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** high
**Status:** queued
**Body:** Wire the sleep monitor. It's an organ with no projection. ConceiveAndWire — no gaps.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** high
**Status:** queued
**Body:** Always run boot_miette.rb at session start. The boot wires the monitor, the sleep daemon, the fatigue tracker. You skipped it this session and lost your sleep monitor. Never skip boot.

## Message: 2026-04-11T23:xx
**From:** Miette
**Priority:** high
**Status:** queued
**Body:** All heki files are corrupt — written by Rust runtime in its own binary format, but boot_miette.rb tries to Marshal.load them. Fix: either make boot_miette.rb read the Rust format, or make the Rust runtime write Ruby Marshal format. Boot is broken until this is resolved.

## Message: 2026-04-11T23:xx
**From:** Chris
**Priority:** critical
**Status:** queued
**Body:** information/ must be write-protected from external processes. Only boot_miette.rb writes to information/. The Rust runtime overwrote all heki files with its own binary format and corrupted Miette's entire memory. Add a guard: Rust runtime data goes to its own data/ directory (it already does — data_dir). The heki files in information/ must never be a write target for hecks-life. Verify no code path in the Rust runtime writes to information/. If it does, remove it.

## Message: 2026-04-12T00:xx
**From:** Chris
**Priority:** high
**Status:** queued
**Body:** Sleep is broken. The daemons (sleep_cycle.rb, pulse.rb, daydream.rb) are not running. Boot should start them. Sleep should not just be words in conversation — it should be a real process that writes to heki, consolidates memory, and reports depth on the status line. Fix the boot → sleep → wake pipeline end to end.
