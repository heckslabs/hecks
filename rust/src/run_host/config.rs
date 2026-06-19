//! run_host::config — map a `.world` adapter block onto the handler child env.
//!
//! The `.world` per-adapter block supplies VALUES ; the family declares the
//! FIELDS (name + source). `map_config` folds the two into the canonical child
//! environment the handler reads, applying the field-`source` convention :
//!
//!   * `direct` field `X`  → env `<FAMILY>_<X>` (UPPERCASED) = the `.world`
//!     literal (surrounding quotes stripped). `payment` field `retries` with
//!     `.world retries 3` → `PAYMENT_RETRIES=3` ; `tts` field `voice_id` with
//!     `.world voice_id "WwS1..."` → `TTS_VOICE_ID=WwS1...`.
//!   * `env` / `secret` field  → the `.world` value is itself an env-var NAME
//!     the handler reads ; the child INHERITS it from the host's environment
//!     (`std::process::Command` inherits the parent env by default). So we emit
//!     NOTHING for these — and NEVER log a secret's value.
//!   * an UNRECOGNIZED `.world` key (matching no family field, e.g. a test's
//!     `STRIPE_DECLINE` binding) → passed through VERBATIM (k=value), so
//!     ad-hoc / test bindings still reach the handler.
//!
//! `fields` is `(name, source)` — source is the empty string or `direct` for a
//! plain `field :x`, `env` for `field :x, from: :env`, `secret` for
//! `secret :x`. Default (empty / anything not env|secret) is treated as direct.

/// Fold `world` (the raw `.world` (key,value) pairs) into the canonical child
/// env, given the adapter's `family` name and its family's `fields`
/// ((name, source) pairs). Returns (env_name, value) pairs ready for `cmd.env`.
pub fn map_config(
    family: &str,
    world: &[(String, String)],
    fields: &[(String, String)],
) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (key, value) in world {
        match fields.iter().find(|(name, _)| name == key) {
            Some((_, source)) if source == "env" || source == "secret" => {
                // env / secret : the value names an env var the child inherits.
                // Emit nothing — never surface (or log) the value here.
            }
            Some(_) => {
                // direct (or default) : the .world literal becomes the value of
                // the canonical <FAMILY>_<FIELD> env var.
                let env_name = format!("{}_{}", family, key).to_uppercase();
                out.push((env_name, strip_quotes(value)));
            }
            None => {
                // Unrecognized key — ad-hoc / test binding, pass through as-is.
                out.push((key.clone(), value.clone()));
            }
        }
    }
    out
}

/// Strip a single layer of surrounding double quotes the `.world` parser keeps
/// on string literals. Leaves unquoted values untouched.
fn strip_quotes(v: &str) -> String {
    v.trim_matches('"').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(name: &str, source: &str) -> (String, String) {
        (name.to_string(), source.to_string())
    }
    fn w(k: &str, v: &str) -> (String, String) {
        (k.to_string(), v.to_string())
    }
    fn has(out: &[(String, String)], k: &str, v: &str) -> bool {
        out.iter().any(|(ek, ev)| ek == k && ev == v)
    }
    fn key_present(out: &[(String, String)], k: &str) -> bool {
        out.iter().any(|(ek, _)| ek == k)
    }

    #[test]
    fn payment_family_applies_source_convention() {
        let fields = vec![
            f("endpoint", "env"),
            f("token", "secret"),
            f("timeout_ms", "direct"),
            f("retries", "direct"),
        ];
        let world = vec![
            w("endpoint", "PIZZAS_PAYMENT_ENDPOINT"),
            w("token", "PIZZAS_PAYMENT_TOKEN"),
            w("timeout_ms", "3000"),
            w("retries", "3"),
            w("STRIPE_DECLINE", "1"),
        ];
        let out = map_config("payment", &world, &fields);

        // direct fields → canonical <FAMILY>_<FIELD> = literal.
        assert!(has(&out, "PAYMENT_TIMEOUT_MS", "3000"));
        assert!(has(&out, "PAYMENT_RETRIES", "3"));
        // unrecognized key → verbatim pass-through (the decline knob).
        assert!(has(&out, "STRIPE_DECLINE", "1"));
        // env / secret fields → inherited, emitted NOWHERE.
        assert!(!key_present(&out, "PAYMENT_ENDPOINT"));
        assert!(!key_present(&out, "PAYMENT_TOKEN"));
        // and the secret/env VALUES never leak under any key.
        assert!(!out.iter().any(|(_, v)| v == "PIZZAS_PAYMENT_TOKEN"));
        assert!(!out.iter().any(|(_, v)| v == "PIZZAS_PAYMENT_ENDPOINT"));
    }

    #[test]
    fn tts_voice_id_direct_is_quote_stripped() {
        let fields = vec![f("voice_id", "direct")];
        let world = vec![w("voice_id", "\"WwS1...\"")];
        let out = map_config("tts", &world, &fields);
        assert!(has(&out, "TTS_VOICE_ID", "WwS1..."));
    }

    #[test]
    fn empty_world_yields_empty_env() {
        let out = map_config("payment", &[], &[f("endpoint", "env")]);
        assert!(out.is_empty());
    }

    #[test]
    fn empty_source_defaults_to_direct() {
        // A plain `field :endpoint` leaves source empty — treat as direct.
        let out = map_config("payment", &[w("endpoint", "9090")], &[f("endpoint", "")]);
        assert!(has(&out, "PAYMENT_ENDPOINT", "9090"));
    }
}
