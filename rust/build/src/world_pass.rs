//! The `world` fact: what the domain's `.world` file says about persistence, read through
//! `hecks-parse world`, so `rust/host` can refuse a world it has no backend for. Only the
//! setting names travel, never their values.

use std::path::Path;

use crate::json::Json;
use crate::subprocess;

/// The `world` fact for `domain`. With no `.world` file beside the domain it is the empty fact.
///
/// # Errors
///
/// Returns the parser's failure, or a message naming output that is not the JSON array
/// `hecks-parse world` prints.
pub fn read(domain: &str, parser_bin: &Path, world: Option<&Path>) -> Result<Json, String> {
    let Some(world) = world else {
        return Ok(fact(None));
    };
    let world_arg = world.to_string_lossy();
    let printed = subprocess::run_capture(&parser_bin.to_string_lossy(), &["world", &world_arg])?;
    let parsed = Json::parse(&printed).map_err(|e| format!("parsing hecks-parse world: {e}"))?;
    let entry = parsed
        .each()
        .iter()
        .find(|w| w.get("domain").and_then(Json::as_str) == Some(domain));
    Ok(fact(entry))
}

/// The world's `default_adapter`, when it names one.
pub fn default_adapter(fact: &Json) -> Option<String> {
    fact.get("default_adapter")
        .and_then(Json::as_str)
        .map(str::to_string)
}

fn fact(entry: Option<&Json>) -> Json {
    let default_adapter = entry
        .and_then(|w| w.get("default_adapter"))
        .and_then(Json::as_str)
        .map_or(Json::Null, |a| Json::String(a.to_string()));
    let default_database = entry
        .and_then(|w| w.get("default_database"))
        .is_some_and(|v| matches!(v, Json::Bool(true)));
    Json::Object(vec![
        ("default_adapter".to_string(), default_adapter),
        ("default_database".to_string(), Json::Bool(default_database)),
        ("persistence".to_string(), Json::Array(persistence(entry))),
    ])
}

fn persistence(entry: Option<&Json>) -> Vec<Json> {
    let bindings = entry
        .and_then(|w| w.get("bindings"))
        .map_or(&[][..], Json::each);
    bindings
        .iter()
        .filter(|b| b.get("verb").and_then(Json::as_str) == Some("persisted_by"))
        .map(|b| {
            Json::Object(vec![
                (
                    "adapter".to_string(),
                    b.get("adapter").cloned().unwrap_or(Json::Null),
                ),
                (
                    "settings".to_string(),
                    b.get("settings")
                        .cloned()
                        .unwrap_or(Json::Array(Vec::new())),
                ),
            ])
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(text: &str) -> Json {
        Json::parse(text).expect("fixture json")
    }

    #[test]
    fn the_default_adapter_is_read_from_the_fact_or_absent() {
        let named = fact(Some(&parsed(
            r#"{"domain":"C","default_adapter":"Heki","bindings":[]}"#,
        )));
        assert_eq!(default_adapter(&named), Some("Heki".to_string()));
        assert_eq!(default_adapter(&fact(None)), None);
    }

    #[test]
    fn fact_keeps_only_persisted_by_bindings_and_the_defaults() {
        let entry = parsed(
            r#"{"domain":"C","default_adapter":"PostgresEra","default_database":true,"bindings":[
              {"verb":"persisted_by","adapter":"PostgresEra","settings":["allow_superuser"]},
              {"verb":"deployed_to","adapter":"AwsLambda","settings":["region"]}]}"#,
        );
        let got = fact(Some(&entry));
        assert_eq!(
            got.get("default_adapter").and_then(Json::as_str),
            Some("PostgresEra")
        );
        assert_eq!(got.get("persistence").map(|p| p.each().len()), Some(1));
        assert!(matches!(
            got.get("default_database"),
            Some(Json::Bool(true))
        ));
    }

    #[test]
    fn fact_for_a_missing_domain_is_empty_not_absent() {
        let got = fact(None);
        assert!(matches!(got.get_raw("default_adapter"), Some(Json::Null)));
        assert_eq!(got.get("persistence").map(|p| p.each().len()), Some(0));
    }
}
