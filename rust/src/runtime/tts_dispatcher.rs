//! [antibody-exempt: rust/src/runtime/tts_dispatcher.rs —
//!  kernel-floor handler for the `:tts` adapter family
//!  (hecks_conception/aggregates/framework/adapter_families/tts.hecksagon).
//!  Implements the `render_text_to_audio` behavior_kind declared in
//!  hecks_conception/aggregates/framework/behavior_kinds/render_text_to_audio.hecksagon.
//!  Sibling kernel-floor port to claude_tool_dispatcher.rs,
//!  sms_dispatcher.rs, and llm_dispatcher.rs ; retires when the
//!  framework-wide kernel-hook registry replaces hard-coded handler
//!  tables (i557).]
//!
//! TtsDispatcher — kernel hook for the :tts adapter family
//!
//! When an Aggregate.Command dispatches and a `:tts` adapter is
//! registered as a `trigger_on:` target, the runtime locates the
//! adapter, reads its `provider:` field + voice_id/model/speed/etc.
//! + the dispatched command's `text` attr, and calls `dispatch`
//! below. `:tts` is fire-and-forget per the family spec
//! (`response_field :none`) — no follow-up command chain.
//!
//! ── Scope ──
//!
//! Real ElevenLabs HTTP integration : POST /v1/text-to-speech/{voice_id}
//! (the standard, NON-streaming endpoint) with a JSON body carrying
//! text + model_id + voice_settings (speed + stability +
//! similarity_boost + style). curl writes the COMPLETE mp3 to a cache
//! file under `cache_dir` keyed by UTC timestamp ; only once the full
//! artifact is on disk is it handed to `mpg123` for playback.
//!
//! ── Non-blocking dispatch, serial playback ──
//!
//! Synthesis + playback (~11s wall-clock) is NOT run inline. After the
//! cheap synchronous pre-flight (provider / text / voice_id / api key /
//! cache_dir — the checks that have a real reason to surface to the
//! caller and stay covered by the unit tests), the whole curl → size-
//! check → mpg123 pipeline is handed to ONE detached `sh -c` child
//! spawned with `.process_group(0)` (its own session). The dispatch
//! then RETURNS IMMEDIATELY (~ms) with `ok: true` and the audio_path
//! the child will write.
//!
//! Why a detached PROCESS, not a thread : the storehouse process for an
//! MCP / cold dispatch is short-lived and exits the instant the
//! dispatch returns. A background thread would die with it ; a child in
//! its own process group survives the parent's exit and finishes the
//! audio. (The `mpg123` player already relied on `.process_group(0)`
//! for exactly this survival — that pattern now wraps the whole
//! synth+play pipeline.)
//!
//! Serial playback : two close Speaks must NOT overlap audibly (f16).
//! Each child acquires a `mkdir`-based lock at
//! `$cache_dir/.tts_play.lock` before calling mpg123, and releases it
//! on exit via a trap. Synthesis (the network leg) is NOT gated —
//! children can pipeline curl in parallel. Only the final mpg123 step
//! serializes. Stale-lock recovery: if the lock dir exists but the PID
//! written inside is no longer alive, the waiting child steals the
//! lock. Unbounded FIFO queue — Miette controls speak frequency.
//!
//! There is NO macOS `say` / Samantha fallback. Chris's rule is
//! verbatim : "I'd rather you not speak than use the default." Pre-
//! flight failures (missing key, no text) return `ok: false` with the
//! reason in `error` for the logs. Synthesis-time failures inside the
//! detached child (HTTP error, tiny error-body response, missing
//! mpg123) stay silent — the child simply exits without playing
//! anything ; never a system voice.
//!
//! Hand-rolled JSON + spawned `curl` (no serde, no reqwest at kernel
//! floor — mirrors the sibling :exec / :llm dispatchers' substrate
//! discipline).

use std::collections::HashMap;
use std::os::unix::process::CommandExt;
use std::process::Stdio;

/// What a `:tts` dispatch produced. `audio_path` is the cached
/// audio file's filesystem location the detached child will write ;
/// empty when pre-flight failed before the pipeline was spawned.
#[derive(Debug, Clone, Default)]
pub struct TtsResult {
    /// Path to the audio file the detached child will render (mp3
    /// today). Empty when the dispatch returned a pre-flight error
    /// before spawning the pipeline.
    pub audio_path: String,
    /// True once the synth+play pipeline was successfully SPAWNED
    /// (detached). It does NOT assert the audio was heard — the child
    /// runs after this returns. False only on pre-flight failure
    /// (config / missing text); there is no fallback voice.
    pub ok: bool,
    /// Human-readable reason when `ok == false`, for the logs.
    pub error: Option<String>,
}

/// Build a silent-failure result : log the reason to stderr (visible
/// under `HECKS_DEBUG_TTS`, harmless otherwise) and return ok=false.
/// We never speak with the macOS default voice. Silence + a logged
/// reason is the contract.
fn silent_fail(reason: &str) -> TtsResult {
    if std::env::var("HECKS_DEBUG_TTS").is_ok() {
        eprintln!("[tts:debug] silent failure : {}", reason);
    }
    TtsResult {
        audio_path: String::new(),
        ok: false,
        error: Some(reason.to_string()),
    }
}

/// Dispatch a `:tts` adapter call. `provider` is the adapter's
/// declared `provider:` field (`"elevenlabs"` today ; `"openai"` /
/// `"piper"` planned). `attrs` carries the dispatched command's
/// attributes (`text` per the behavior_kind's `trigger_attribute`)
/// plus the adapter instance fields the resolver folded in
/// (voice_id, model, speed, …, auto_play).
///
/// Returns the instant the detached synth+play child is spawned — the
/// ~11s of network synthesis and playback happen in that child, after
/// this function has returned.
pub fn dispatch(provider: &str, attrs: &HashMap<String, String>) -> TtsResult {
    if provider != "elevenlabs" {
        return TtsResult {
            audio_path: String::new(),
            ok: false,
            error: Some(format!(
                "tts dispatcher : provider {:?} not implemented (only elevenlabs)",
                provider
            )),
        };
    }
    let text = match attrs.get("text") {
        Some(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => return TtsResult {
            audio_path: String::new(),
            ok: false,
            error: Some("tts dispatcher : no `text` attr to render".into()),
        },
    };

    let home = std::env::var("HOME").unwrap_or_default();

    // Provider-side config : voice_id is required ; everything else
    // falls back to a default so a hecksagon that declares only
    // voice_id still renders the right voice.
    let voice_id = match attrs.get("voice_id") {
        Some(v) if !v.is_empty() => v.clone(),
        _ => return silent_fail("no `voice_id` (set it on the :tts adapter)"),
    };
    // Default to eleven_turbo_v2_5 : the fast model that preserves the
    // WwS1 (Björk-tone) voice. The old eleven_v3 default is deprecated
    // for HTTP synthesis and degraded the voice ; the live voice.hecksagon
    // overrides this anyway, but the constant on the page should match
    // reality so a non-overriding caller still gets the right voice.
    let model = attrs.get("model").cloned().unwrap_or_else(|| "eleven_turbo_v2_5".into());
    let speed = attrs.get("speed").cloned().unwrap_or_else(|| "1.2".into());

    // Optional emotion knobs. Passed through only when the adapter
    // declares them so bluebook-tuned voices ride through without
    // code changes.
    let stability = attrs.get("stability").cloned();
    let similarity = attrs.get("similarity_boost").cloned();
    let style = attrs.get("style").cloned();

    // API key — silent failure when absent (no `say` fallback).
    let key_path = format!("{}/.config/miette/elevenlabs.key", home);
    let api_key = match std::fs::read_to_string(&key_path) {
        Ok(k) => k.trim().to_string(),
        Err(e) => return silent_fail(&format!("cannot read {} ({})", key_path, e)),
    };
    if api_key.is_empty() {
        return silent_fail(&format!("empty api key at {}", key_path));
    }

    // Cache dir resolves ~/ → $HOME and is created on demand.
    let cache_dir_raw = attrs.get("cache_dir").cloned()
        .unwrap_or_else(|| "~/.config/miette/audio".to_string());
    let cache_dir = match cache_dir_raw.strip_prefix('~') {
        Some(rest) => format!("{}{}", home, rest),
        None => cache_dir_raw,
    };
    if let Err(e) = std::fs::create_dir_all(&cache_dir) {
        return silent_fail(&format!("cannot create cache_dir {} ({})", cache_dir, e));
    }
    // miette_{YYYYMMDDTHHMMSS}.mp3 — UTC, matches the shell bridge's
    // filename convention so audit listings span both eras byte-equal.
    let audio_path = format!("{}/miette_{}.mp3", cache_dir, utc_compact());

    // voice_settings : speed is always present ; stability /
    // similarity_boost / style are included only when the adapter
    // declared them.
    let mut settings = format!("\"speed\":{}", parse_float_or(&speed, 1.2));
    if let Some(s) = &stability {
        settings.push_str(&format!(",\"stability\":{}", parse_float_or(s, 0.5)));
    }
    if let Some(s) = &similarity {
        settings.push_str(&format!(",\"similarity_boost\":{}", parse_float_or(s, 0.75)));
    }
    if let Some(s) = &style {
        settings.push_str(&format!(",\"style\":{}", parse_float_or(s, 0.0)));
    }
    let body = format!(
        "{{\"text\":\"{}\",\"model_id\":\"{}\",\"voice_settings\":{{{}}}}}",
        json_escape(&text), model, settings
    );
    // Standard, non-streaming endpoint : curl writes the COMPLETE mp3
    // to disk before mpg123 plays it. No `/stream` suffix.
    let url = format!("https://api.elevenlabs.io/v1/text-to-speech/{}", voice_id);

    let auto_play = attrs.get("auto_play")
        .map(|s| matches!(s.as_str(), "true" | "1" | "yes"))
        .unwrap_or(true);

    if std::env::var("HECKS_DEBUG_TTS").is_ok() {
        eprintln!("[tts:debug] POST {}", url);
        eprintln!("[tts:debug] body {}", body);
        eprintln!("[tts:debug] mp3  {}", audio_path);
        eprintln!("[tts:debug] auto_play {}", auto_play);
    }

    // ── The detached synth+play pipeline ──
    //
    // Everything network/playback-bound runs in ONE child shell so the
    // dispatch returns now (~ms) instead of blocking ~11s. The shell:
    //   1. POSTs to ElevenLabs, writing the complete mp3 to $TTS_OUT.
    //   2. Guards against the tiny JSON error-body ElevenLabs returns
    //      on failure (a real mp3 is comfortably > 1024 bytes) ; on a
    //      too-small file it removes it and exits silently — no play,
    //      no fallback voice.
    //   3. Acquires a mkdir-based serial playback lock (f16) then plays
    //      the finished file with mpg123 (unless auto_play off) and
    //      releases the lock on EXIT/signal via a trap.
    //
    // text + api key + url + out path travel via env (`Command::env`),
    // never interpolated into the shell string — `text`'s quotes /
    // newlines (already JSON-escaped in $TTS_BODY) would otherwise
    // fight shell quoting. The script body references only fixed env
    // names, so it is a constant string with nothing to escape.
    //
    // `.process_group(0)` puts the child in its own session so it
    // survives this storehouse process exiting (cold MCP dispatch).
    // Playback is serialized via a mkdir lock inside the child shell
    // so concurrent dispatches queue at the mpg123 step rather than
    // overlapping. stdio is nulled so the detached child holds no
    // handles on the parent's pipes.

    // Serial playback lock path — stable across all concurrent children.
    let lock_dir = format!("{}/.tts_play.lock", cache_dir);
    let lock_pid_file = format!("{}/pid", lock_dir);

    let play_step = if auto_play {
        // Lock acquisition: mkdir is atomic on macOS HFS+/APFS.
        // We spin in 100ms increments, checking each time whether the
        // PID inside the lock is still alive (stale-lock recovery). On
        // owning the lock we write our PID so a later child can steal
        // a stale one. The trap releases the lock on any exit — normal,
        // signal, or error — so mpg123 can be a plain call (not exec)
        // and the trap fires reliably.
        "TTS_LOCK=\"$TTS_LOCK_DIR\"; \
         TTS_PID_FILE=\"$TTS_LOCK_PID\"; \
         while ! mkdir \"$TTS_LOCK\" 2>/dev/null; do \
           if [ -f \"$TTS_PID_FILE\" ]; then \
             lp=$(cat \"$TTS_PID_FILE\" 2>/dev/null); \
             if [ -n \"$lp\" ] && ! kill -0 \"$lp\" 2>/dev/null; then \
               rm -rf \"$TTS_LOCK\"; continue; \
             fi; \
           fi; \
           sleep 0.1; \
         done; \
         echo $$ > \"$TTS_PID_FILE\"; \
         trap 'rm -rf \"$TTS_LOCK\"' EXIT INT TERM HUP; \
         /opt/homebrew/bin/mpg123 -q \"$TTS_OUT\""
    } else {
        ":"
    };
    let script = format!(
        "curl -s -X POST \"$TTS_URL\" \
           -H \"xi-api-key: $XI_API_KEY\" \
           -H 'Content-Type: application/json' \
           -H 'Accept: audio/mpeg' \
           -d \"$TTS_BODY\" \
           --output \"$TTS_OUT\" || exit 0; \
         sz=$(wc -c < \"$TTS_OUT\" 2>/dev/null || echo 0); \
         if [ \"$sz\" -le 1024 ]; then rm -f \"$TTS_OUT\"; exit 0; fi; \
         {}",
        play_step
    );

    let spawned = std::process::Command::new("/bin/sh")
        .arg("-c").arg(&script)
        .env("TTS_URL", &url)
        .env("XI_API_KEY", &api_key)
        .env("TTS_BODY", &body)
        .env("TTS_OUT", &audio_path)
        .env("TTS_LOCK_DIR", &lock_dir)
        .env("TTS_LOCK_PID", &lock_pid_file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn();

    match spawned {
        Ok(_) => TtsResult { audio_path, ok: true, error: None },
        Err(e) => silent_fail(&format!("cannot spawn synth+play pipeline ({})", e)),
    }
}

/// UTC compact timestamp (YYYYMMDDTHHMMSS) — matches the shell
/// bridge's `date +%Y%m%dT%H%M%S` for byte-equal filenames across
/// the kernel and shell eras.
fn utc_compact() -> String {
    // Hand-rolled because we deliberately don't pull in `chrono` at
    // the kernel floor. SystemTime → seconds since epoch → calendar
    // breakdown via the standard Julian-day arithmetic.
    let secs = crate::clock::now_duration().as_secs();
    let (y, mo, d, h, mi, s) = epoch_to_utc(secs);
    format!("{:04}{:02}{:02}T{:02}{:02}{:02}", y, mo, d, h, mi, s)
}

/// Convert UNIX epoch seconds into (year, month, day, hour, minute,
/// second) tuple in UTC. Standard civil-from-days algorithm
/// (Howard Hinnant). Valid for every date the project will see.
fn epoch_to_utc(secs: u64) -> (i32, u32, u32, u32, u32, u32) {
    let days = (secs / 86_400) as i64;
    let secs_of_day = (secs % 86_400) as u32;
    let h = secs_of_day / 3_600;
    let mi = (secs_of_day % 3_600) / 60;
    let s = secs_of_day % 60;
    let z = days + 719_468;
    let era = if z >= 0 { z / 146_097 } else { (z - 146_096) / 146_097 };
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = (y + if m <= 2 { 1 } else { 0 }) as i32;
    (y, m, d, h, mi, s)
}

/// Parse a string like "1.2" or "0.5" into a float, falling back to
/// `default` on parse failure. Used for voice_settings knobs so a
/// malformed hecksagon value still renders rather than 500'ing.
fn parse_float_or(s: &str, default: f64) -> f64 {
    s.trim().parse::<f64>().unwrap_or(default)
}

/// Minimal JSON string escaper for the `text` field (no serde at
/// kernel floor — mirrors the hand-rolled JSON in sibling
/// dispatchers).
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attrs(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn unknown_provider_is_rejected() {
        let r = dispatch("piper", &attrs(&[("text", "hi")]));
        assert!(!r.ok);
        assert!(r.audio_path.is_empty());
        assert!(r.error.unwrap().contains("not implemented"));
    }

    #[test]
    fn missing_text_is_rejected_without_network() {
        let r = dispatch("elevenlabs", &attrs(&[("voice_id", "abc")]));
        assert!(!r.ok);
        assert!(r.error.unwrap().contains("no `text`"));
    }

    #[test]
    fn json_escape_handles_quotes_and_newlines() {
        assert_eq!(json_escape("a\"b\nc"), "a\\\"b\\nc");
    }

    #[test]
    fn parse_float_or_falls_back_on_garbage() {
        assert_eq!(parse_float_or("1.5", 0.0), 1.5);
        assert_eq!(parse_float_or("not-a-number", 9.0), 9.0);
    }

    #[test]
    fn utc_compact_shape_is_yyyymmddthhmmss() {
        // Epoch zero → "19700101T000000". Pin the algorithm to a
        // known input so a future refactor that breaks the calendar
        // math fails loudly.
        assert_eq!(super::epoch_to_utc(0), (1970, 1, 1, 0, 0, 0));
    }
}
