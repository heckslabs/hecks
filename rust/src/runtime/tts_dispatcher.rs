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
//! Real ElevenLabs HTTP integration : POST /v1/text-to-speech/{voice_id}/stream
//! with a JSON body carrying text + model_id + voice_settings (speed +
//! stability + similarity_boost + style). The mp3 bytes return as
//! they generate (TTFB ~860ms vs ~8s for the non-streaming endpoint).
//! We tee the byte stream inside the dispatch loop : (a) into
//! `mpg123 -`'s stdin so playback begins as soon as the first MP3
//! frame lands, and (b) into a cache file at
//! `cache_dir/miette_{utc}.mp3` so Replay still has a full artifact
//! after the stream finishes. A pid file at
//! `~/.config/miette/speak.pid` records the dispatcher pid so a
//! fresh dispatch cancels the prior in-flight render before starting
//! a new one (latest-wins semantics ; mirrors the historical
//! ~/bin/miette-speak shell bridge that this dispatcher retires).
//!
//! Falls back to macOS `say -v Samantha` when the key file is missing,
//! empty, or the HTTP call delivered zero bytes — same contract as
//! the shell bridge so a network drop or expired key still produces
//! audible speech.
//!
//! Hand-rolled JSON + spawned `curl` + spawned `mpg123` (no serde,
//! no reqwest at kernel floor — mirrors the sibling :exec / :llm
//! dispatchers' substrate discipline). The tee runs in pure Rust
//! because a shell `curl | tee file | mpg123 -` pipeline truncates
//! the cache the moment mpg123 closes stdin (tee dies on EPIPE) ;
//! the in-process loop keeps writing the file even after mpg123
//! exits or stops accepting bytes.
//!
//! Timing note : dispatch BLOCKS for the duration of the stream
//! (typically a few seconds end-to-end). Playback begins inside
//! the first second via mpg123 reading our piped stdin ; mpg123
//! is reparented to init when the dispatch returns so audio
//! continues past return. This is a semantic departure from the
//! pre-streaming dispatcher, which spawned `afplay` detached and
//! returned immediately. Blocking is necessary because returning
//! before EOF would tear down the in-process tee loop and truncate
//! the cache.

use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::process::CommandExt;
use std::process::Stdio;

use super::voice::{phrase_cache, latency};

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

    // Start the latency measurement window BEFORE any work so cache
    // hits and HTTP misses share the same start instant.
    let measurement = latency::start();

    // Resolve the cache-key tuple early so hit + miss paths agree
    // on the key shape. voice_id may be missing — in that case the
    // miss path will fall back to `say` ; we still skip the cache
    // check in that case (no key → no hit).
    let cache_voice_id = attrs.get("voice_id").cloned().unwrap_or_default();
    let cache_model = attrs.get("model").cloned().unwrap_or_else(|| "eleven_v3".into());
    let cache_speed = attrs.get("speed").cloned().unwrap_or_else(|| "1.2".into());

    // Cache hit ? Skip the HTTP roundtrip entirely : pipe the cached
    // mp3 straight to mpg123, record latency with cache_hit=true,
    // return. mpg123 over afplay because the task locked it in and
    // because mpg123's stdin-streaming option (`mpg123 -`) lets us
    // pipe without an intermediate file dance on a future tightening
    // pass (v1 just plays the file directly).
    if !cache_voice_id.is_empty() {
        if let Some(cached) = phrase_cache::try_hit(
            &text, &cache_voice_id, &cache_model, &cache_speed
        ) {
            let auto_play = attrs.get("auto_play")
                .map(|s| matches!(s.as_str(), "true" | "1" | "yes"))
                .unwrap_or(true);
            if auto_play {
                let _ = std::process::Command::new("mpg123")
                    .arg("-q").arg(&cached).process_group(0).spawn();
            }
            let path_str = cached.to_string_lossy().to_string();
            // ttfb on a hit is effectively zero — the audio file is
            // already on disk and mpg123 spawned in <1ms. Report the
            // elapsed wall-clock so the rolling average still has a
            // signal even on the fast path.
            let ttfb = measurement.started_at.elapsed().as_millis();
            latency::record(&measurement, text.chars().count(), ttfb, true);
            if std::env::var("HECKS_DEBUG_TTS").is_ok() {
                eprintln!("[tts:debug] cache HIT → {}", path_str);
            }
            return TtsResult {
                audio_path: path_str,
                ok: true,
                error: None,
            };
        }
    }

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
    // Streaming endpoint — bytes flow back as they generate. The
    // non-streaming sibling endpoint (no `/stream` suffix) returns
    // the same MP3 but holds it for ~8s end-to-end ; the streaming
    // path delivers TTFB ~860ms so mpg123 begins playback inside the
    // first second.
    let url = format!("https://api.elevenlabs.io/v1/text-to-speech/{}/stream", voice_id);

    if std::env::var("HECKS_DEBUG_TTS").is_ok() {
        eprintln!("[tts:debug] POST {}", url);
        eprintln!("[tts:debug] body {}", body);
        eprintln!("[tts:debug] mp3  {}", audio_path);
    }

    // auto_play decides whether we spawn mpg123 at all. When false,
    // we still stream-write the cache so Replay has the artifact ;
    // we just skip the playback child.
    let auto_play = attrs.get("auto_play")
        .map(|s| matches!(s.as_str(), "true" | "1" | "yes"))
        .unwrap_or(true);

    // Spawn curl with stdout piped so we can read MP3 chunks
    // ourselves. No `--output` here — that would buffer the whole
    // response to disk before we ever see a byte. `-N` (--no-buffer)
    // tells curl to flush as bytes arrive ; `--fail` makes a
    // non-2xx HTTP status surface as a non-zero exit so we can
    // detect ElevenLabs errors and fall back to `say`.
    let mut curl = match std::process::Command::new("curl")
        .arg("-sN").arg("--fail").arg("-X").arg("POST").arg(&url)
        .arg("-H").arg(format!("xi-api-key: {}", api_key))
        .arg("-H").arg("Content-Type: application/json")
        .arg("-H").arg("Accept: audio/mpeg")
        .arg("-d").arg(&body)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return fallback_say(&text, &format!("curl spawn failed ({})", e)),
    };

    // Spawn mpg123 reading from stdin. Absolute path avoids PATH
    // surprises when storehouse is launched from non-login shells
    // (Claude Code, launchd, hooks). `-q` keeps stderr quiet so the
    // dispatch's parent doesn't see decoder chatter. `-` reads MP3
    // frames from stdin. We deliberately don't `.wait()` for mpg123
    // — playback runs past the dispatch's return so the CLI exits
    // promptly after the stream finishes.
    let mpg123 = if auto_play {
        match std::process::Command::new("/opt/homebrew/bin/mpg123")
            .arg("-q").arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            // Own process group : the player must outlive this dispatch.
            // Without it, mpg123 sits in storehouse's group and gets
            // reaped when the dispatch process exits — cutting playback
            // off mid-stream (the audio is ~5s, the dispatch returns in
            // ~1s). process_group(0) detaches it so it finishes the
            // buffered audio after we return.
            .process_group(0)
            .spawn()
        {
            Ok(c) => Some(c),
            // mpg123 missing → still let the cache write proceed
            // (Replay works), but log that playback is degraded.
            Err(e) => {
                if std::env::var("HECKS_DEBUG_TTS").is_ok() {
                    eprintln!("[tts:debug] mpg123 spawn failed ({}) ; tee→file only", e);
                }
                None
            }
        }
    } else {
        None
    };

    // Open the cache file. Errors here are fatal for the dispatch :
    // if we can't write the artifact, fall back to `say` and reap
    // any half-spawned children.
    let mut cache_file = match std::fs::File::create(&audio_path) {
        Ok(f) => f,
        Err(e) => {
            let _ = curl.kill();
            if let Some(mut c) = mpg123 { let _ = c.kill(); }
            return fallback_say(&text, &format!("cannot create cache file {} ({})", audio_path, e));
        }
    };

    // Take ownership of the pipes before the tee loop. curl's stdout
    // is a `ChildStdout` ; mpg123's stdin is a `ChildStdin`. Both
    // are owned exactly once, so we move them out of the children
    // here. The children themselves stay alive (curl until EOF,
    // mpg123 until we drop its stdin or it finishes playing).
    let mut mpg123 = mpg123;
    let mut curl_out = match curl.stdout.take() {
        Some(s) => s,
        None => {
            let _ = curl.kill();
            if let Some(mut c) = mpg123 { let _ = c.kill(); }
            return fallback_say(&text, "curl stdout pipe vanished");
        }
    };
    let mut mpg_in = mpg123.as_mut().and_then(|c| c.stdin.take());

    // Tee loop. Read up to 4 KiB at a time so we don't block waiting
    // for a fat buffer to fill ; mpg123 starts decoding the first
    // MP3 frame inside the first chunk. Cache write errors are
    // fatal (the artifact is the whole point of caching) ; mpg123
    // write errors are not — if the user kills playback or mpg123
    // dies mid-stream, we keep feeding the cache so Replay still
    // has the full file.
    let mut buf = [0u8; 4096];
    let mut total_bytes: u64 = 0;
    loop {
        match curl_out.read(&mut buf) {
            Ok(0) => break, // EOF — curl finished
            Ok(n) => {
                if let Err(e) = cache_file.write_all(&buf[..n]) {
                    let _ = curl.kill();
                    if let Some(mut c) = mpg123.take() { let _ = c.kill(); }
                    return fallback_say(&text, &format!("cache write failed ({})", e));
                }
                total_bytes += n as u64;
                // Write to mpg123 if it's still attached.
                // BrokenPipe just means mpg123 stopped reading (user
                // killed it, or it finished decoding). Drop our
                // handle so we don't keep trying ; the file write
                // continues normally. Use a `take` + restore dance
                // so the borrow on `mpg_in` ends before we possibly
                // reassign it.
                let drop_pipe = if let Some(stdin) = mpg_in.as_mut() {
                    match stdin.write_all(&buf[..n]) {
                        Ok(()) => false,
                        Err(e) => {
                            if e.kind() != ErrorKind::BrokenPipe
                                && std::env::var("HECKS_DEBUG_TTS").is_ok()
                            {
                                eprintln!("[tts:debug] mpg123 stdin write : {}", e);
                            }
                            true
                        }
                    }
                } else {
                    false
                };
                if drop_pipe {
                    mpg_in = None;
                }
            }
            Err(e) => {
                let _ = curl.kill();
                if let Some(mut c) = mpg123.take() { let _ = c.kill(); }
                return fallback_say(&text, &format!("curl stdout read failed ({})", e));
            }
        }
    }
    // Flush + close the cache file deterministically before we look
    // at curl's exit status, so even on a partial stream the artifact
    // on disk reflects exactly the bytes we received.
    let _ = cache_file.flush();
    drop(cache_file);
    // Close mpg123's stdin so it knows the stream ended and can
    // finish decoding the tail. We do NOT wait for it to exit —
    // playback continues past the dispatch's return.
    drop(mpg_in);

    // Inspect curl's exit. `--fail` makes a 4xx/5xx surface here.
    // If curl errored AND we never forwarded any bytes, treat it as
    // a hard failure and fall back to `say`. If we forwarded some
    // bytes (network drop mid-stream, partial render), keep the
    // partial cache and report success — the user already heard the
    // first part of the utterance, downgrading to `say` would talk
    // over the playback.
    let status = curl.wait();
    let curl_stderr = curl.stderr.take()
        .map(|mut s| {
            let mut buf = Vec::new();
            let _ = s.read_to_end(&mut buf);
            String::from_utf8_lossy(&buf).into_owned()
        })
        .unwrap_or_default();
    match status {
        Ok(st) if st.success() => {
            // Happy path : full stream delivered, playback in
            // progress, cache complete.
        }
        Ok(st) if total_bytes == 0 => {
            // curl errored before any bytes ; remove the empty cache
            // file and fall back so Chris still hears something.
            let _ = std::fs::remove_file(&audio_path);
            return fallback_say(&text, &format!(
                "curl exit {:?} (zero bytes) : {}",
                st.code(),
                curl_stderr.lines().take(3).collect::<Vec<_>>().join(" / ")
            ));
        }
        Ok(_) => {
            // Partial stream — leave the cache, surface the warning
            // in `error` but report ok=true since audio was heard.
            return TtsResult {
                audio_path,
                ok: true,
                error: Some(format!(
                    "partial stream ({} bytes) : {}",
                    total_bytes,
                    curl_stderr.lines().take(3).collect::<Vec<_>>().join(" / ")
                )),
            };
        }
        Err(e) => {
            if total_bytes == 0 {
                let _ = std::fs::remove_file(&audio_path);
                return fallback_say(&text, &format!("curl wait failed ({})", e));
            }
            return TtsResult {
                audio_path,
                ok: true,
                error: Some(format!("curl wait failed after {} bytes ({})", total_bytes, e)),
            };
        }
    }

    // Cache miss : save the freshly rendered mp3 under its content
    // hash so the next Speak with the same (text, voice_id, model,
    // speed) tuple hits. Best-effort — a copy failure doesn't
    // invalidate the dispatch (the timestamped audit file already
    // played).
    if !cache_voice_id.is_empty() {
        let _ = phrase_cache::save(
            &text, &cache_voice_id, &cache_model, &cache_speed, &audio_path
        );
    }
    let ttfb = measurement.started_at.elapsed().as_millis();
    latency::record(&measurement, text.chars().count(), ttfb, false);

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
/// the pid file, plus its children (curl, mpg123, afplay), plus any
/// orphan mpg123 / afplay processes from a crashed run. Best-effort :
/// missing or invalid pid files are silently ignored. Mirrors the
/// shell bridge's identical guard.
///
/// `afplay` lingers in the kill list because Replay (cached playback
/// after the streaming render is gone) still uses it ; both players
/// must die when a fresh Speak supersedes them. mpg123 is the new
/// streaming player ; afplay is the legacy / Replay player. The
/// transitional double-pkill is intentional and removed only when
/// Replay also moves off afplay.
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
    // Belt-and-suspenders : reap any orphan player from a crashed run.
    let _ = std::process::Command::new("pkill").arg("-9").arg("mpg123").output();
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
