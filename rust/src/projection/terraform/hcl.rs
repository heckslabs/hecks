//! HCL emission — pure string formatting from key/value pairs.
//!
//! Produces canonical HCL2 blocks :
//!
//!   resource "aws_s3_bucket" "events_store" {
//!     bucket     = "events-store-2026"
//!     versioning = "enabled"
//!   }
//!
//! No attempt at fancy formatting (terraform fmt would be the canonical
//! normalizer if the caller wants it) ; just two-space indentation,
//! equal-sign-separated key/value, alphabetically sorted property keys
//! so the output is deterministic for golden testing.

use crate::world_ir::World;

/// Emit a single `resource "<type>" "<name>" { ... }` block. Property
/// keys are sorted alphabetically so the output is byte-stable across
/// runs (golden-test contract).
pub fn resource_block(
    resource_type: &str,
    name: &str,
    props: &[(String, String)],
) -> String {
    let mut sorted: Vec<&(String, String)> = props.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut out = String::new();
    out.push_str(&format!("resource \"{}\" \"{}\" {{\n", resource_type, name));
    if sorted.is_empty() {
        // Keep the block valid even when no properties land (helpful
        // for the smallest-possible projection). Terraform accepts an
        // empty body but reserves type-specific required attrs at
        // plan time.
    } else {
        let max_key = sorted.iter().map(|(k, _)| k.len()).max().unwrap_or(0);
        for (k, v) in sorted {
            out.push_str(&format!(
                "  {:<width$} = {}\n",
                k,
                format_value(v),
                width = max_key
            ));
        }
    }
    out.push_str("}\n");
    out
}

/// Emit the AWS provider block from the world's `aws do ... end`
/// block, when present. Returns `None` when the world has no aws block
/// — the projector then skips the provider stanza and lets the operator
/// configure the provider externally (terraform init -backend-config,
/// AWS_PROFILE env, etc.).
pub fn provider_block_for(world: &World) -> Option<String> {
    let aws = world.config_for("aws")?;
    let mut out = String::from("provider \"aws\" {\n");
    let max_key = aws.values.iter().map(|(k, _)| k.len()).max().unwrap_or(0);
    let mut sorted: Vec<&(String, String)> = aws.values.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    for (k, v) in sorted {
        out.push_str(&format!(
            "  {:<width$} = {}\n",
            k,
            format_value(v),
            width = max_key
        ));
    }
    out.push_str("}\n");
    Some(out)
}

/// Render a raw value-string as an HCL literal. Heuristic :
///   - "true" / "false"     → bare boolean
///   - integer-shaped       → bare number
///   - already-quoted       → kept verbatim
///   - anything else        → wrapped in double quotes
///
/// The bluebook contract says world / hecksagon option values are
/// stored as their source-token textual form (see world_parser /
/// hecksagon_parser docs) ; this function decides how to express each
/// in HCL.
fn format_value(v: &str) -> String {
    let t = v.trim();
    if t == "true" || t == "false" {
        return t.to_string();
    }
    if t.parse::<i64>().is_ok() {
        return t.to_string();
    }
    if t.starts_with('"') && t.ends_with('"') && t.len() >= 2 {
        return t.to_string();
    }
    format!("\"{}\"", t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resource_block_alphabetises_props() {
        let props = vec![
            ("versioning".into(), "enabled".into()),
            ("bucket".into(),     "events-store-2026".into()),
        ];
        let hcl = resource_block("aws_s3_bucket", "events_store", &props);
        // bucket appears before versioning (alphabetical order).
        let bucket_pos = hcl.find("bucket").unwrap();
        let version_pos = hcl.find("versioning").unwrap();
        assert!(bucket_pos < version_pos);
    }

    #[test]
    fn format_value_handles_booleans_integers_strings() {
        assert_eq!(format_value("true"),    "true");
        assert_eq!(format_value("42"),      "42");
        assert_eq!(format_value("hello"),   "\"hello\"");
        assert_eq!(format_value("\"x\""),   "\"x\"");
    }

    #[test]
    fn empty_props_yields_empty_body_block() {
        let hcl = resource_block("aws_s3_bucket", "x", &[]);
        assert!(hcl.contains("resource \"aws_s3_bucket\" \"x\" {"));
        assert!(hcl.contains("}"));
    }
}
