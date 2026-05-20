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
//! with a JSON body carrying text + model_id + voice_settings (speed +
//! stability + similarity_boost + style). The mp3 response lands in
//! `cache_dir` keyed by UTC timestamp ; afplay plays it detached so
//! the dispatch returns immediately. A pid file at
//! `~/.config/miette/speak.pid` records the wrapper process id so a
//! fresh dispatch cancels the prior in-flight render before starting
//! a new one (latest-wins semantics ; mirrors the historical
//! ~/bin/miette-speak shell bridge that this dispatcher retires).
//!
//! Falls back to macOS `say -v Samantha` when the key file is missing,
//! empty, or the API call fails — same contract as the shell bridge
//! so a network drop or expired key still produces audible speech.
//!
//! Hand-rolled JSON + spawned `curl` (no serde, no reqwest at kernel
//! floor — mirrors the sibling :exec / :llm dispatchers' substrate
//! discipline).

use std::collections::HashMap;
use std::io::Write;

/// What a `:tts` dispatch produced. `audio_path` is the cached
/// audio file's filesystem location ; empty when the fallback path
/// (macOS `say`) ran instead of the ElevenLabs render.
#[derive(Debug, Clone, Default)]
pub struct TtsResult {
    /// Path to the rendered audio file on disk (mp3 today). Empty
    /// when the dispatch fell back to `say` or returned an error
    /// before the file was written.
    pub audio_path: String,
    /// True if audio reached the speakers (ElevenLabs render or the
    /// `say` fallback both count — what matters is that Chris heard
    /// something). False only on dispatch-shape errors (missing
    /// `text`, unknown provider) before any audio path is attempted.
    pub ok: bool,
    /// Human-readable error when `ok == false`, or a fallback note
    /// (`"fellback to say (…)"`) when ElevenLabs failed but `say`
    /// took over.
    pub error: Option<String>,
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
    // its children first (curl + afplay) then the wrapper. Belt-
    // and-suspenders also pkill any orphan `afplay` left from a
    // prior crash. Mirrors ~/bin/miette-speak's identical guard.
    let pid_file = format!("{}/.config/miette/speak.pid", home);
    cancel_prior_render(&pid_file);
    let _ = std::fs::create_dir_all(format!("{}/.config/miette", home));
    let _ = std::fs::File::create(&pid_file).and_then(|mut f| {
        write!(f, "{}", std::process::id())
    });

    // Provider-side config : voice_id is required ; everything else
    // falls back to the shell bridge's defaults so a hecksagon that
    // declares only voice_id still renders.
    let voice_id = match attrs.get("voice_id") {
        Some(v) if !v.is_empty() => v.clone(),
        _ => return fallback_say(&text, "no `voice_id` (set it on the :tts adapter)"),
    };
    let model = attrs.get("model").cloned().unwrap_or_else(|| "eleven_v3".into());
    let speed = attrs.get("speed").cloned().unwrap_or_else(|| "1.2".into());

    // Optional emotion knobs. The shell bridge omitted these by
    // default ; we pass them when the adapter declares them so
    // bluebook-tuned voices ride through without code changes.
    let stability = attrs.get("stability").cloned();
    let similarity = attrs.get("similarity_boost").cloned();
    let style = attrs.get("style").cloned();

    // API key — fallback to `say` when absent, matching the shell.
    let key_path = format!("{}/.config/miette/elevenlabs.key", home);
    let api_key = match std::fs::read_to_string(&key_path) {
        Ok(k) => k.trim().to_string(),
        Err(e) => return fallback_say(&text, &format!("cannot read {} ({})", key_path, e)),
    };
    if api_key.is_empty() {
        return fallback_say(&text, &format!("empty api key at {}", key_path));
    }

    // Cache dir resolves ~/ → $HOME and is created on demand.
    let cache_dir_raw = attrs.get("cache_dir").cloned()
        .unwrap_or_else(|| "~/.config/miette/audio".to_string());
    let cache_dir = match cache_dir_raw.strip_prefix('~') {
        Some(rest) => format!("{}{}", home, rest),
        None => cache_dir_raw,
    };
    if let Err(e) = std::fs::create_dir_all(&cache_dir) {
        return fallback_say(&text, &format!("cannot create cache_dir {} ({})", cache_dir, e));
    }
    // miette_{YYYYMMDDTHHMMSS}.mp3 — UTC, matches the shell bridge's
    // filename convention so audit listings span both eras byte-equal.
    let audio_path = format!("{}/miette_{}.mp3", cache_dir, utc_compact());

    // voice_settings : speed is always present (defaults to 1.2 from
    // the shell bridge) ; stability / similarity_boost / style are
    // included only when the adapter declared them.
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
            return fallback_say(&text, &format!("curl exit {:?} : {}", o.status.code(), stderr));
        }
        Err(e) => return fallback_say(&text, &format!("curl spawn failed ({})", e)),
    }
    // ElevenLabs returns a small JSON error body (not audio) on
    // failure. Treat a too-small file as an error, surface the
    // body for diagnosis, and fall back to `say`.
    match std::fs::metadata(&audio_path) {
        Ok(m) if m.len() > 1024 => {}
        Ok(m) => {
            let snippet = std::fs::read_to_string(&audio_path).unwrap_or_default();
            let _ = std::fs::remove_file(&audio_path);
            return fallback_say(&text, &format!(
                "response too small ({} bytes) : {}",
                m.len(), snippet.chars().take(200).collect::<String>()));
        }
        Err(e) => return fallback_say(&text, &format!("no audio file written ({})", e)),
    }

    // Play the rendered audio. auto_play defaults true — the dispatch
    // is a one-shot voice command, silently writing the mp3 without
    // playing is almost never what the caller wanted. Detach so the
    // dispatch returns immediately ; the supervised pid file lets
    // the next call cancel this playback if a fresher one arrives.
    let auto_play = attrs.get("auto_play")
        .map(|s| matches!(s.as_str(), "true" | "1" | "yes"))
        .unwrap_or(true);
    if auto_play {
        let _ = std::process::Command::new("afplay").arg(&audio_path).spawn();
    }

    TtsResult { audio_path, ok: true, error: None }
}

/// Fallback : run macOS `say -v Samantha "{text}"` and report it as a
/// successful dispatch (audio reached Chris's ears) with the reason
/// folded into the error field so logs can still attribute the
/// downgrade. Mirrors miette-speak's `fallback()` shell function.
fn fallback_say(text: &str, reason: &str) -> TtsResult {
    let _ = std::process::Command::new("say")
        .arg("-v").arg("Samantha")
        .arg(text)
        .spawn();
    TtsResult {
        audio_path: String::new(),
        ok: true,
        error: Some(format!("fellback to say ({})", reason)),
    }
}

/// Kill the prior `miette-speak` / `tts dispatch` wrapper recorded in
/// the pid file, plus its children (curl, afplay), plus any orphan
/// afplay processes from a crashed run. Best-effort : missing or
/// invalid pid files are silently ignored. Mirrors the shell
/// bridge's identical guard.
fn cancel_prior_render(pid_file: &str) {
    if let Ok(s) = std::fs::read_to_string(pid_file) {
        if let Ok(pid) = s.trim().parse::<i32>() {
            // Kill children first so the wrapper doesn't dive into its
            // fallback path on signal ; then the wrapper itself.
            let _ = std::process::Command::new("pkill")
                .arg("-P").arg(pid.to_string()).output();
            let _ = std::process::Command::new("kill")
                .arg("-9").arg(pid.to_string()).output();
        }
    }
    // Belt-and-suspenders : reap any orphan afplay from a crashed run.
    let _ = std::process::Command::new("pkill").arg("-9").arg("afplay").output();
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
