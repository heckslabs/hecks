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
//! This is a v1 stub. The contract surface (function signature +
//! `TtsResult` shape) is intentionally locked so real provider
//! integration (ElevenLabs HTTP POST to /v1/text-to-speech) drops
//! into the stub's slot without rippling the caller side. No HTTP
//! calls are made today — `dispatch` returns `ok: false` with a
//! descriptive "v1 stub" error so misconfigured rollouts fail
//! loudly rather than silently no-op.

use std::collections::HashMap;

/// What a `:tts` dispatch produced. `audio_path` is the cached
/// audio file's filesystem location (populated when the family's
/// `cache_dir:` field is set + the render succeeds) ; the stub
/// leaves it empty until real integration lands.
#[derive(Debug, Clone, Default)]
pub struct TtsResult {
    /// Path to the rendered audio file on disk (mp3 today).
    pub audio_path: String,
    /// True if the provider rendered audio.
    pub ok: bool,
    /// Human-readable error when `ok == false`.
    pub error: Option<String>,
}

/// Dispatch a `:tts` adapter call. `provider` is the adapter's
/// declared `provider:` field (`"elevenlabs"` today ; `"openai"` /
/// `"piper"` planned). `attrs` carries the dispatched command's
/// attributes (`text` per the behavior_kind's `trigger_attribute`).
///
/// Real ElevenLabs integration : POST `text` to
/// /v1/text-to-speech/{voice_id}, write the mp3 under `cache_dir`,
/// and (when `auto_play` is truthy) play it detached via `afplay`.
/// Network / file / exec failures return `ok: false` with a
/// descriptive error rather than panicking, so a misconfigured
/// rollout fails loudly, not silently. No serde at kernel floor :
/// the request JSON is hand-rolled, mirroring the sibling
/// dispatchers' curl shape.
pub fn dispatch(provider: &str, attrs: &HashMap<String, String>) -> TtsResult {
    let err = |m: String| TtsResult { audio_path: String::new(), ok: false, error: Some(m) };
    if provider != "elevenlabs" {
        return err(format!("tts dispatcher : provider {:?} not implemented (only elevenlabs)", provider));
    }
    let text = match attrs.get("text") {
        Some(t) if !t.trim().is_empty() => t.clone(),
        _ => return err("tts dispatcher : no `text` attr to render".into()),
    };
    let voice_id = match attrs.get("voice_id") {
        Some(v) if !v.is_empty() => v.clone(),
        _ => return err("tts dispatcher : no `voice_id` (set it on the :tts adapter)".into()),
    };
    let model = attrs.get("model").cloned().unwrap_or_else(|| "eleven_v3".to_string());
    let stability = attrs.get("stability").cloned().unwrap_or_else(|| "0.5".to_string());
    let similarity = attrs.get("similarity_boost").cloned().unwrap_or_else(|| "0.75".to_string());
    let style = attrs.get("style").cloned().unwrap_or_else(|| "0.0".to_string());

    let home = std::env::var("HOME").unwrap_or_default();
    let key_path = format!("{}/.config/miette/elevenlabs.key", home);
    let api_key = match std::fs::read_to_string(&key_path) {
        Ok(k) => k.trim().to_string(),
        Err(e) => return err(format!("tts dispatcher : cannot read {} ({})", key_path, e)),
    };
    if api_key.is_empty() {
        return err(format!("tts dispatcher : empty api key at {}", key_path));
    }

    let cache_dir_raw = attrs.get("cache_dir").cloned()
        .unwrap_or_else(|| "~/.config/miette/audio".to_string());
    let cache_dir = match cache_dir_raw.strip_prefix('~') {
        Some(rest) => format!("{}{}", home, rest),
        None => cache_dir_raw,
    };
    if let Err(e) = std::fs::create_dir_all(&cache_dir) {
        return err(format!("tts dispatcher : cannot create cache_dir {} ({})", cache_dir, e));
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let audio_path = format!("{}/miette_{}_{}.mp3", cache_dir, ts, std::process::id());

    let body = format!(
        "{{\"text\":\"{}\",\"model_id\":\"{}\",\"voice_settings\":{{\"stability\":{},\"similarity_boost\":{},\"style\":{}}}}}",
        json_escape(&text), model, stability, similarity, style
    );
    let url = format!("https://api.elevenlabs.io/v1/text-to-speech/{}", voice_id);

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
        Ok(o) => return err(format!(
            "tts dispatcher : curl exit {:?} : {}",
            o.status.code(), String::from_utf8_lossy(&o.stderr))),
        Err(e) => return err(format!("tts dispatcher : curl spawn failed ({})", e)),
    }
    // ElevenLabs returns a small JSON error body (not audio) on
    // failure ; treat a too-small file as an error and surface it.
    match std::fs::metadata(&audio_path) {
        Ok(m) if m.len() > 1024 => {}
        Ok(m) => {
            let snippet = std::fs::read_to_string(&audio_path).unwrap_or_default();
            return err(format!(
                "tts dispatcher : response too small ({} bytes) : {}",
                m.len(), snippet.chars().take(200).collect::<String>()));
        }
        Err(e) => return err(format!("tts dispatcher : no audio file written ({})", e)),
    }

    if matches!(attrs.get("auto_play").map(|s| s.as_str()), Some("true") | Some("1") | Some("yes")) {
        // Detached : fire-and-forget, do not block the dispatch path.
        let _ = std::process::Command::new("afplay").arg(&audio_path).spawn();
    }

    TtsResult { audio_path, ok: true, error: None }
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
}
