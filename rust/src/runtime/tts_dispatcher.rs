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
//! artifact is on disk do we hand it to `mpg123` for playback. This
//! is the simple, robust path : the dispatch does not block on a live
//! byte stream and is safe against the Stop hook's process lifecycle
//! (the streaming dispatcher that briefly replaced this blocked until
//! stream EOF and broke the Stop-hook reading — reverted 2026-05-22).
//!
//! `mpg123` is spawned with `.process_group(0)` so the player survives
//! the dispatch's return (the audio outlives the CLI process). We do
//! NOT wait for it. A pid file at `~/.config/miette/speak.pid` records
//! the dispatcher pid so a fresh dispatch cancels the prior in-flight
//! render (latest-wins ; mirrors the historical ~/bin/miette-speak
//! shell bridge this dispatcher retires).
//!
//! There is NO macOS `say` / Samantha fallback. Chris's rule is
//! verbatim : "I'd rather you not speak than use the default." When
//! synthesis fails (missing key, HTTP error, tiny error-body
//! response), we stay silent and return `ok: false` with the reason in
//! `error` for the logs — no audible degraded voice.
//!
//! Hand-rolled JSON + spawned `curl` (no serde, no reqwest at kernel
//! floor — mirrors the sibling :exec / :llm dispatchers' substrate
//! discipline).

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::process::CommandExt;

/// What a `:tts` dispatch produced. `audio_path` is the cached
/// audio file's filesystem location ; empty when synthesis failed
/// before a complete artifact was written.
#[derive(Debug, Clone, Default)]
pub struct TtsResult {
    /// Path to the rendered audio file on disk (mp3 today). Empty
    /// when the dispatch returned an error before the file was
    /// written.
    pub audio_path: String,
    /// True only when a complete ElevenLabs mp3 was synthesized (and
    /// played, if auto_play). False on any failure — there is no
    /// fallback, so a false here means Chris heard nothing.
    pub ok: bool,
    /// Human-readable reason when `ok == false`, for the logs.
    pub error: Option<String>,
}

/// Build a silent-failure result : log the reason to stderr (visible
/// under `HECKS_DEBUG_TTS`, harmless otherwise) and return ok=false.
/// Replaces the old `fallback_say` — we never speak with the macOS
/// default voice. Silence + a logged reason is the contract.
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

    // Cancel any in-flight prior render. Each invocation supersedes
    // the previous : if the pid file points at a live process, kill
    // its children first (curl + mpg123) then the wrapper. Belt-
    // and-suspenders also pkill any orphan player left from a prior
    // crash. Mirrors ~/bin/miette-speak's identical guard.
    let pid_file = format!("{}/.config/miette/speak.pid", home);
    cancel_prior_render(&pid_file);
    let _ = std::fs::create_dir_all(format!("{}/.config/miette", home));
    let _ = std::fs::File::create(&pid_file).and_then(|mut f| {
        write!(f, "{}", std::process::id())
    });

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
    // to disk before we play it. No `/stream` suffix — that blocked
    // the dispatch on a live byte stream and broke the Stop hook.
    let url = format!("https://api.elevenlabs.io/v1/text-to-speech/{}", voice_id);

    if std::env::var("HECKS_DEBUG_TTS").is_ok() {
        eprintln!("[tts:debug] POST {}", url);
        eprintln!("[tts:debug] body {}", body);
        eprintln!("[tts:debug] mp3  {}", audio_path);
    }

    let out = std::process::Command::new("curl")
        .arg("-s").arg("-X").arg("POST").arg(&url)
        .arg("-H").arg(format!("xi-api-key: {}", api_key))
        .arg("-H").arg("Content-Type: application/json")
        .arg("-H").arg("Accept: audio/mpeg")
        .arg("-d").arg(&body)
        .arg("--output").arg(&audio_path)
        .output();
    match out {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr).into_owned();
            return silent_fail(&format!("curl exit {:?} : {}", o.status.code(), stderr));
        }
        Err(e) => return silent_fail(&format!("curl spawn failed ({})", e)),
    }
    // ElevenLabs returns a small JSON error body (not audio) on
    // failure. Treat a too-small file as an error, surface the body
    // for diagnosis, and stay silent (no fallback voice).
    match std::fs::metadata(&audio_path) {
        Ok(m) if m.len() > 1024 => {}
        Ok(m) => {
            let snippet = std::fs::read_to_string(&audio_path).unwrap_or_default();
            let _ = std::fs::remove_file(&audio_path);
            return silent_fail(&format!(
                "response too small ({} bytes) : {}",
                m.len(), snippet.chars().take(200).collect::<String>()));
        }
        Err(e) => return silent_fail(&format!("no audio file written ({})", e)),
    }

    // Play the finished audio file. auto_play defaults true — the
    // dispatch is a one-shot voice command. mpg123 with an explicit
    // path (the complete mp3 already on disk) ; absolute binary path
    // avoids PATH surprises when storehouse is launched from
    // non-login shells (Claude Code, launchd, hooks). `-q` keeps the
    // decoder quiet. `.process_group(0)` detaches the player into its
    // own group so it survives this dispatch's return and finishes
    // the audio — the supervised pid file lets the next call cancel
    // it if a fresher Speak arrives. We deliberately do NOT wait.
    let auto_play = attrs.get("auto_play")
        .map(|s| matches!(s.as_str(), "true" | "1" | "yes"))
        .unwrap_or(true);
    if auto_play {
        let _ = std::process::Command::new("/opt/homebrew/bin/mpg123")
            .arg("-q").arg(&audio_path)
            .process_group(0)
            .spawn();
    }

    TtsResult { audio_path, ok: true, error: None }
}

/// Kill the prior `tts dispatch` wrapper recorded in the pid file,
/// plus its children (curl, mpg123), plus any orphan mpg123 from a
/// crashed run. Best-effort : missing or invalid pid files are
/// silently ignored. Mirrors the shell bridge's identical guard.
fn cancel_prior_render(pid_file: &str) {
    if let Ok(s) = std::fs::read_to_string(pid_file) {
        if let Ok(pid) = s.trim().parse::<i32>() {
            // Kill children first so the wrapper doesn't dive into a
            // late code path on signal ; then the wrapper itself.
            let _ = std::process::Command::new("pkill")
                .arg("-P").arg(pid.to_string()).output();
            let _ = std::process::Command::new("kill")
                .arg("-9").arg(pid.to_string()).output();
        }
    }
    // Belt-and-suspenders : reap any orphan player from a crashed run.
    let _ = std::process::Command::new("pkill").arg("-9").arg("mpg123").output();
}

/// UTC compact timestamp (YYYYMMDDTHHMMSS) — matches the shell
/// bridge's `date +%Y%m%dT%H%M%S` for byte-equal filenames across
/// the kernel and shell eras.
fn utc_compact() -> String {
    // Hand-rolled because we deliberately don't pull in `chrono` at
    // the kernel floor. SystemTime → seconds since epoch → calendar
    // breakdown via the standard Julian-day arithmetic.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
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
