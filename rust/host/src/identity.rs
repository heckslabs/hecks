//! The `identity_generation` port (`lib/hecks/ports/identity_generation.port`), answered by the
//! Rust host. The Ruby side binds `SecureRandomIdentity`; this is the same fulfillment for a
//! caller that dispatches through the host, so the mint is one adapter on each side, never a
//! second binding in the Ruby registry.

use serde_json::{json, Value};

/// The port's name, as the bluebook declares it.
pub const PORT: &str = "identity_generation";

/// A fresh random identity: a version-4 UUID, as `SecureRandomIdentity.uuid` mints.
#[must_use]
pub fn mint_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// The answer to `{"port": "identity_generation"}`, or `None` when `body` is some other request.
///
/// The answer names the verb (`generated_by`) and carries the minted value under `uuid`, the
/// port's declared `answers :uuid`.
#[must_use]
pub fn answer(body: &Value) -> Option<Value> {
    let port = body.get("port")?.as_str()?;
    (port == PORT).then(|| json!({ "port": PORT, "verb": "generated_by", "uuid": mint_uuid() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_answer_is_a_fresh_version_four_uuid() {
        let first = answer(&json!({ "port": PORT })).expect("the port is answered");
        let second = answer(&json!({ "port": PORT })).expect("the port is answered");
        let uuid = uuid::Uuid::parse_str(first["uuid"].as_str().unwrap()).unwrap();
        assert_eq!(uuid.get_version_num(), 4);
        assert_ne!(first["uuid"], second["uuid"]);
        assert_eq!(first["verb"], "generated_by");
    }

    #[test]
    fn any_other_body_is_not_this_port() {
        assert!(answer(&json!({ "port": "clock" })).is_none());
        assert!(answer(&json!({ "verb": "Register", "args": {} })).is_none());
        assert!(answer(&json!({ "port": 7 })).is_none());
    }
}
