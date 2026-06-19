//! tts-handler (Rust) — a standalone, COMPILED out-of-process `:tts` ADAPTER
//! program. The compiled sibling of tts-handler.rb ; the two are behaviour-parity
//! (same ElevenLabs call, same serial-playback lock, same silent-fail contract).
//!
//! This is the OUT-OF-PROCESS replacement for the in-runtime
//! rust/src/runtime/tts_dispatcher.rs kernel hook. The runtime only parses
//! bluebooks + drains the OutboundEvent outbox (Runtime::pump_outbound_events) ;
//! it knows NOTHING about TTS. The IMPURE synthesis + playback lives here.
//!
//! THE ADAPTER CAN BLOCK. `voiced_by` is fire-and-forget FROM THE BLUEBOOK : the
//! domain emits `Spoke` and moves on, no verdict re-enters the DOMAIN. Because this
//! program runs OUT-OF-PROCESS (the pump detach-spawns it), it is free to BLOCK on
//! the ~11s of synth + playback — the synchronous domain core already returned. So
//! there is NO detached grandchild here : a standalone bin runs the work to
//! completion, blocking, then RE-ENTERS THE DOOR.
//!
//! RE-ENTRY IS THE ADAPTER'S JOB, NOT A PURE HANDLER'S. After the audio finishes,
//! this bin marks the outbox delivery DELIVERED — closing the OutboundEvent so the
//! next pump cycle doesn't re-claim + re-speak. It re-enters ONLY through the
//! GENERIC door command the pump handed it in env (HECKS_DELIVERED_COMMAND), never
//! hardcoding TTS-specific runtime knowledge : the door is the public interface.
//!
//! ADAPTER-HOST CONTRACT (mirrors tts-handler.rb / stripe-handler) :
//!   * STDIN : the trigger event payload as JSON (carries `text` to render).
//!   * ENV   : the adapter instance config the pump folds in from .world, under the
//!             canonical <FAMILY>_<FIELD> names adapter_env::map_config emits —
//!             TTS_VOICE_ID (required), TTS_MODEL, TTS_SPEED, TTS_STABILITY,
//!             TTS_SIMILARITY_BOOST, TTS_STYLE, TTS_CACHE_DIR, TTS_AUTO_PLAY ; plus
//!             the re-entry contract HECKS_STOREHOUSE_BIN / HECKS_ROOT /
//!             HECKS_DELIVERY_ID / HECKS_DELIVERED_COMMAND. There is no provider
//!             knob : THIS bin IS the elevenlabs adapter.
//!   * EXIT  : 0 always. Pre-flight failures exit 0 silently : Chris's rule is
//!             verbatim — "I'd rather you not speak than use the default." There is
//!             NO macOS `say` fallback, ever.
//!
//! The api key is read from ~/.config/miette/elevenlabs.key and passed to the
//! blocking child via env, never interpolated into the shell string.
//!
//! Build (standalone, zero deps) :
//!   rustc -O adapters/tts/tts-handler.rs -o adapters/tts/tts-handler

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

/// Log under HECKS_DEBUG_TTS, harmless otherwise.
fn debug(msg: &str) {
    if std::env::var("HECKS_DEBUG_TTS").is_ok() {
        eprintln!("[tts-handler:rs] {}", msg);
    }
}

/// Silent failure : log the reason, re-enter the door (the delivery is HANDLED —
/// a pre-flight failure is not retryable, :tts never re-queues), exit 0. We never
/// speak with a fallback voice.
fn silent_exit(reason: &str) -> ! {
    debug(&format!("silent failure : {}", reason));
    mark_delivered();
    std::process::exit(0);
}

fn env_opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

/// Re-enter the door : mark the outbox delivery DELIVERED. The ADAPTER does this,
/// not a pure handler. Guarded on the env being present so the standalone
/// smoke-test (no pump, no env) still works unchanged. Re-enters ONLY the generic
/// FQN command the pump handed us — no TTS-specific storehouse knowledge baked in.
fn mark_delivered() {
    if let (Some(bin), Some(root), Some(did), Some(cmd)) = (
        env_opt("HECKS_STOREHOUSE_BIN"),
        env_opt("HECKS_ROOT"),
        env_opt("HECKS_DELIVERY_ID"),
        env_opt("HECKS_DELIVERED_COMMAND"),
    ) {
        debug(&format!("{} delivery_id={} via {} {}", cmd, did, bin, root));
        let _ = Command::new(&bin)
            .arg(&root)
            .arg(&cmd)
            .arg(format!("delivery_id={}", did))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

/// Extract a JSON string value for `key` from `src`, decoding standard escapes.
/// UTF-8 safe. Minimal by design — the payload is a flat object like
/// {"text":"..."} ; we never need a full JSON parser here.
fn json_string_field(src: &str, key: &str) -> Option<String> {
    let pat = format!("\"{}\"", key);
    let start = src.find(&pat)? + pat.len();
    let rest = &src[start..];
    let colon = rest.find(':')?;
    let after = &rest[colon + 1..];
    let q = after.find('"')?;
    let mut out = String::new();
    let mut chars = after[q + 1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('/') => out.push('/'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some('b') => out.push('\u{08}'),
                Some('f') => out.push('\u{0C}'),
                Some('u') => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Ok(n) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(n) {
                            out.push(ch);
                        }
                    }
                }
                Some(other) => out.push(other),
                None => break,
            },
            '"' => return Some(out),
            _ => out.push(c),
        }
    }
    None
}

/// Escape a string for embedding as a JSON string value.
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
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

/// Parse a float-ish env value, falling back ; render with a decimal point so the
/// JSON number matches the Ruby handler's Float()#to_s (0.0, not 0).
fn fnum(raw: Option<&str>, default: f64) -> String {
    let n = raw.and_then(|s| s.trim().parse::<f64>().ok()).unwrap_or(default);
    let s = format!("{}", n);
    if s.contains('.') || s.contains('e') { s } else { format!("{}.0", s) }
}

/// UTC YYYYMMDDTHHMMSS from epoch seconds (Hinnant days->civil ; no chrono dep).
fn utc_stamp(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}{:02}{:02}T{:02}{:02}{:02}", y, m, d, h, mi, s)
}

fn main() {
    // ── text : from the event payload on stdin ──
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    let text = json_string_field(&raw, "text").unwrap_or_default();
    let text = text.trim().to_string();
    if text.is_empty() {
        silent_exit("no `text` in event payload");
    }

    let home = std::env::var("HOME").unwrap_or_default();

    // ── provider config : voice_id required, the rest fall back to the WwS1 voice ──
    let voice_id = match env_opt("TTS_VOICE_ID") {
        Some(v) => v,
        None => silent_exit("no TTS_VOICE_ID (set voice_id on the :tts adapter / .world)"),
    };
    let model = env_opt("TTS_MODEL").unwrap_or_else(|| "eleven_turbo_v2_5".into());
    let speed = env_opt("TTS_SPEED").unwrap_or_else(|| "1.2".into());
    let stability = env_opt("TTS_STABILITY");
    let similarity = env_opt("TTS_SIMILARITY_BOOST");
    let style = env_opt("TTS_STYLE");

    // ── api key : silent fail when absent (no fallback voice) ──
    let key_path = format!("{}/.config/miette/elevenlabs.key", home);
    let api_key = std::fs::read_to_string(&key_path)
        .map(|k| k.trim().to_string())
        .unwrap_or_default();
    if api_key.is_empty() {
        silent_exit(&format!("cannot read {}", key_path));
    }

    // ── cache dir : resolve ~/ and create on demand ──
    let cache_raw = env_opt("TTS_CACHE_DIR").unwrap_or_else(|| "~/.config/miette/audio".into());
    let cache_dir = if let Some(rest) = cache_raw.strip_prefix('~') {
        format!("{}{}", home, rest)
    } else {
        cache_raw
    };
    let _ = std::fs::create_dir_all(&cache_dir);

    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let audio_path = format!("{}/{}_{}.mp3", cache_dir, utc_stamp(secs), std::process::id());

    // ── voice_settings JSON ──
    let mut settings = format!("\"speed\":{}", fnum(Some(&speed), 1.2));
    if let Some(v) = &stability {
        settings.push_str(&format!(",\"stability\":{}", fnum(Some(v), 0.5)));
    }
    if let Some(v) = &similarity {
        settings.push_str(&format!(",\"similarity_boost\":{}", fnum(Some(v), 0.75)));
    }
    if let Some(v) = &style {
        settings.push_str(&format!(",\"style\":{}", fnum(Some(v), 0.0)));
    }

    let body = format!(
        "{{\"text\":\"{}\",\"model_id\":\"{}\",\"voice_settings\":{{{}}}}}",
        json_escape(&text), json_escape(&model), settings
    );
    let url = format!("https://api.elevenlabs.io/v1/text-to-speech/{}", voice_id);
    let auto_play = matches!(
        env_opt("TTS_AUTO_PLAY").unwrap_or_else(|| "true".into()).to_lowercase().as_str(),
        "true" | "1" | "yes"
    );

    let lock_dir = format!("{}/.tts_play.lock", cache_dir);
    let lock_pid = format!("{}/pid", lock_dir);

    // Serial playback (f16) : a mkdir lock so two close Speaks never overlap
    // audibly. Stale-lock recovery : steal the lock if its PID is no longer alive.
    let play_step = if auto_play {
        "while ! mkdir \"$TTS_LOCK_DIR\" 2>/dev/null; do if [ -f \"$TTS_LOCK_PID\" ]; then lp=$(cat \"$TTS_LOCK_PID\" 2>/dev/null); if [ -n \"$lp\" ] && ! kill -0 \"$lp\" 2>/dev/null; then rm -rf \"$TTS_LOCK_DIR\"; continue; fi; fi; sleep 0.1; done; echo $$ > \"$TTS_LOCK_PID\"; trap 'rm -rf \"$TTS_LOCK_DIR\"' EXIT INT TERM HUP; /opt/homebrew/bin/mpg123 -q \"$TTS_OUT\""
    } else {
        ":"
    };

    // curl writes the COMPLETE mp3 before playback ; a <=1024-byte file is the JSON
    // error body ElevenLabs returns on failure — drop it and stop silently.
    let script = format!(
        "curl -s -X POST \"$TTS_URL\" -H \"xi-api-key: $XI_API_KEY\" -H 'Content-Type: application/json' -H 'Accept: audio/mpeg' -d \"$TTS_BODY\" --output \"$TTS_OUT\" || exit 0; sz=$(wc -c < \"$TTS_OUT\" 2>/dev/null || echo 0); if [ \"$sz\" -le 1024 ]; then rm -f \"$TTS_OUT\"; exit 0; fi; {}",
        play_step
    );

    // BLOCKING synth + play : the adapter runs out-of-process, so it CAN block —
    // the synchronous domain core already returned. No detached child : the
    // standalone bin runs the curl + mpg123 pipeline to completion, then re-enters.
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(&script)
        .env("TTS_URL", &url)
        .env("XI_API_KEY", &api_key)
        .env("TTS_BODY", &body)
        .env("TTS_OUT", &audio_path)
        .env("TTS_LOCK_DIR", &lock_dir)
        .env("TTS_LOCK_PID", &lock_pid)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    match status {
        Ok(s) => debug(&format!("synth+play done ({}) -> {}", s, audio_path)),
        Err(e) => debug(&format!("synth+play failed to run : {}", e)),
    }

    // Re-enter the door regardless of synth outcome : the delivery is HANDLED (we
    // attempted it ; :tts has no retry — a missed utterance is missed, never
    // re-queued). MarkDelivered closes the outbox row.
    mark_delivered();
    std::process::exit(0);
}
