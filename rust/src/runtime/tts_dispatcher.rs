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
/// v1 stub : returns `ok: false` with a stub error. Real provider
/// integration (ElevenLabs /v1/text-to-speech POST, write bytes
/// under `cache_dir:`) drops in here without changing the
/// signature.
pub fn dispatch(_provider: &str, _attrs: &HashMap<String, String>) -> TtsResult {
    TtsResult {
        audio_path: String::new(),
        ok: false,
        error: Some("tts dispatcher : v1 stub — no provider integration yet".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attrs(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn stub_returns_not_ok_with_descriptive_error() {
        let r = dispatch("elevenlabs", &attrs(&[
            ("text", "hello, world"),
        ]));
        assert!(!r.ok);
        assert!(r.audio_path.is_empty());
        let err = r.error.expect("stub must populate error");
        assert!(err.contains("v1 stub"), "unexpected error text: {}", err);
    }
}
