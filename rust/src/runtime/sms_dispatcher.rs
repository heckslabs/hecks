//! [antibody-exempt: rust/src/runtime/sms_dispatcher.rs —
//!  kernel-floor handler for the `:sms` adapter family
//!  (hecks_conception/aggregates/framework/adapter_families/sms.hecksagon).
//!  Implements the `call_sms_api` behavior_kind : outbound SMS send
//!  via a configured provider (Twilio today ; Vonage / MessageBird
//!  siblings later). Sibling kernel-floor port to
//!  claude_tool_dispatcher.rs and llm_dispatcher.rs ; retires when
//!  the framework-wide kernel-hook registry replaces hard-coded
//!  handler tables (i557).]
//!
//! SmsDispatcher — kernel hook for the :sms adapter family
//!
//! When an Aggregate.Command dispatches and a `:sms` adapter is
//! registered as a `trigger_on:` target, the runtime locates the
//! adapter, reads its `provider:` field + the dispatched command's
//! attrs (e.g. `to`, `from`, `body`), and calls `dispatch` below.
//!
//! ── Scope ──
//!
//! This is a v1 stub. The contract surface (function signature +
//! `SmsResult` shape) is intentionally locked so real provider
//! integration (Twilio HTTP POST to /Messages.json) drops into the
//! stub's slot without rippling the caller side. No HTTP calls are
//! made today — `dispatch` returns `ok: false` with a descriptive
//! "v1 stub" error so misconfigured rollouts fail loudly rather
//! than silently no-op.

use std::collections::HashMap;

/// What an `:sms` dispatch produced. `message_sid` is the
/// provider's identifier for the queued message (Twilio returns
/// `SMxxxx…`) ; the stub leaves it empty until real integration
/// lands.
#[derive(Debug, Clone, Default)]
pub struct SmsResult {
    /// Provider's message identifier (Twilio SID, Vonage UUID, etc.).
    pub message_sid: String,
    /// True if the provider accepted the send.
    pub ok: bool,
    /// Human-readable error when `ok == false`.
    pub error: Option<String>,
}

/// Dispatch an `:sms` adapter call. `provider` is the adapter's
/// declared `provider:` field (`"twilio"` today). `attrs` carries
/// the dispatched command's attributes (`to`, `from`, `body`).
///
/// v1 stub : returns `ok: false` with a stub error. Real provider
/// integration (Twilio /Messages.json POST) drops in here without
/// changing the signature.
pub fn dispatch(_provider: &str, _attrs: &HashMap<String, String>) -> SmsResult {
    SmsResult {
        message_sid: String::new(),
        ok: false,
        error: Some("sms dispatcher : v1 stub — no provider integration yet".into()),
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
        let r = dispatch("twilio", &attrs(&[
            ("to", "+15555550100"),
            ("from", "+15555550199"),
            ("body", "hello"),
        ]));
        assert!(!r.ok);
        assert!(r.message_sid.is_empty());
        let err = r.error.expect("stub must populate error");
        assert!(err.contains("v1 stub"), "unexpected error text: {}", err);
    }
}
