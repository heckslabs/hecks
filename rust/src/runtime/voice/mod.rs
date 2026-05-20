//! [antibody-exempt: rust/src/runtime/voice/ — kernel-floor module
//!  group implementing the Voice bluebook's PhraseCache + LatencyTelemetry
//!  aggregates (hecks_conception/aggregates/miette/body/voice/voice.bluebook).
//!  Split from tts_dispatcher.rs to keep that file under the 200-LoC
//!  ceiling ; mod.rs is the thin facade, phrase_cache.rs handles the
//!  on-disk hash→mp3 store, latency.rs handles the measurement +
//!  rolling-5 ring + heki persistence. Retires when the framework-wide
//!  kernel-hook registry (i557) absorbs the :tts family's wrappers.]
//!
//! Voice — phrase cache + latency telemetry around :tts dispatch
//!
//! Two responsibilities, two submodules :
//!
//!   * `phrase_cache` — content-addressed mp3 store at
//!     `~/.config/miette/audio/phrase_cache/<sha256>.mp3`. Key is
//!     `sha256(text + voice_id + model_id + speed)`. On hit the
//!     cached mp3 plays via `mpg123` and we skip the ElevenLabs
//!     HTTP roundtrip entirely. On miss the existing render path
//!     writes the mp3 under both the timestamp-keyed audit name
//!     AND the hash-keyed cache name, so the next Speak with the
//!     same tuple hits.
//!
//!   * `latency` — per-Speak measurement (first-token-to-first-sound
//!     `ttfb_ms` + `total_ms`), persisted as a `Voice.Latency` event
//!     and reduced into a rolling-5 ring on the `LatencyTelemetry`
//!     singleton (`voice_latency.heki`). The statusline reads that
//!     singleton to render the `🔊 <avg>ms <hit%>` segment.
//!
//! The dispatcher (tts_dispatcher.rs) calls into these in two
//! places : `phrase_cache::try_hit` at the top (returns `Some(path)`
//! if cached), `phrase_cache::save` after a successful HTTP render,
//! and `latency::record` once per dispatch (regardless of hit/miss).

pub mod phrase_cache;
pub mod latency;
