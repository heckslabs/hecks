//! Wasm components a domain's hecksagon wires to its ports (the IR's `components` key): each
//! entry names the adapter, the port it answers, its module with its SHA-256, and the grant the
//! host cuts for it (the secret names and hosts it declared). A port no entry names is answered
//! natively, as before components existed.

use crate::module_cache;
use serde_json::Value;
use std::path::PathBuf;

/// A component wired to a port, its module written to the cache and its grant as declared.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wired {
    pub adapter: String,
    pub module: PathBuf,
    pub secrets: Vec<String>,
    pub hosts: Vec<String>,
}

/// The component the IR wires to `port`: `None` when it wires none, `Some(Err)` when it names
/// one whose entry is broken (no module, a module that is not its digest), so a deploy that
/// names a component never falls back to the native adapter unnoticed.
pub fn wired(domain_ir: Option<&Value>, port: &str) -> Option<Result<Wired, String>> {
    let entry = domain_ir?
        .get("components")?
        .as_array()?
        .iter()
        .find(|entry| entry["port"] == port)?;
    Some(load(entry))
}

fn load(entry: &Value) -> Result<Wired, String> {
    let text = |key: &str| entry[key].as_str().unwrap_or_default();
    let adapter = text("adapter").to_string();
    let module = module_cache::cached(&adapter, text("sha256"), text("module"))?;
    Ok(Wired {
        adapter,
        module,
        secrets: strings(&entry["secrets"]),
        hosts: strings(&entry["hosts"]),
    })
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| item.as_str().map(String::from))
        .collect()
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use base64::Engine as _;
    use serde_json::json;
    use sha2::{Digest, Sha256};

    const MODULE: &[u8] = b"\0asm component bytes";

    fn ir(sha256: &str) -> Value {
        json!({ "components": [{
            "adapter": "Resend", "port": "email", "verb": "mailed_by", "runs": "resend.wasm",
            "sha256": sha256, "module": base64::engine::general_purpose::STANDARD.encode(MODULE),
            "secrets": ["RESEND_API_KEY"], "imports": ["clock", "http_out"], "hosts": ["api.resend.com"],
        }]})
    }

    #[test]
    fn finds_the_component_wired_to_a_port_with_its_grant() {
        let ir = ir(&module_cache::hex(&Sha256::digest(MODULE)));
        let found = wired(Some(&ir), "email").unwrap().unwrap();
        assert_eq!(
            (found.adapter.as_str(), found.secrets, found.hosts),
            (
                "Resend",
                vec!["RESEND_API_KEY".to_string()],
                vec!["api.resend.com".to_string()]
            )
        );
        assert_eq!(std::fs::read(found.module).unwrap(), MODULE);
    }

    #[test]
    fn a_port_no_component_is_wired_to_is_answered_natively() {
        let ir = ir(&module_cache::hex(&Sha256::digest(MODULE)));
        assert!(wired(Some(&ir), "payments").is_none());
        assert!(wired(Some(&json!({})), "email").is_none());
        assert!(wired(None, "email").is_none());
    }

    #[test]
    fn refuses_a_component_whose_module_is_not_its_digest() {
        let ir = ir(&"1".repeat(64));
        assert_eq!(
            wired(Some(&ir), "email").unwrap(),
            Err("Resend's module does not match its digest".to_string())
        );
    }
}
