//! Adapter-kind → Terraform resource-type mapping table.
//!
//! Closed set : these are the kinds the Phase 1 projector knows about.
//! Adding a kind is a two-step change : append the row here, and add a
//! matching `value_object` in the TerraformProjector bluebook so the
//! contract stays in sync. The integration test in
//! rust/tests/terraform_projection_test.rs catches drift via goldens.
//!
//! Kinds that are present in the hecksagon DSL but have no cloud-resource
//! analog (:memory, :stdout, :tts, :llm, :compute, :exec, :shell,
//! :web_tool, :env, :fs, :stdin) are deliberately ABSENT — the projector
//! returns None for them and the caller skips the resource block. That
//! is the documented Phase 1 contract.

/// Look up the Terraform resource type for a hecksagon adapter kind.
/// Returns `None` when the kind has no mapping (caller skips the block).
pub fn resource_type_for(kind: &str) -> Option<&'static str> {
    match kind {
        // AWS — the Phase 1 target. Sibling :gcp_*, :azurerm_* tables
        // arrive in Phase 2 once we prove the projection mechanism.
        "s3"       => Some("aws_s3_bucket"),
        "sqs"      => Some("aws_sqs_queue"),
        "lambda"   => Some("aws_lambda_function"),
        "dynamodb" => Some("aws_dynamodb_table"),
        "sns"      => Some("aws_sns_topic"),

        // No mapping : Phase 1 skips these silently. They are the
        // hecksagon DSL's runtime-side adapter kinds, not cloud
        // resources. The same kinds appear in the bluebook's
        // documentation block of `AdapterKindMapping` as the reason
        // for their absence.
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_aws_kinds() {
        assert_eq!(resource_type_for("s3"),       Some("aws_s3_bucket"));
        assert_eq!(resource_type_for("sqs"),      Some("aws_sqs_queue"));
        assert_eq!(resource_type_for("lambda"),   Some("aws_lambda_function"));
        assert_eq!(resource_type_for("dynamodb"), Some("aws_dynamodb_table"));
        assert_eq!(resource_type_for("sns"),      Some("aws_sns_topic"));
    }

    #[test]
    fn skips_runtime_only_kinds() {
        // These kinds are present in the hecksagon DSL but have no
        // cloud-resource analog ; the projector silently skips them.
        for kind in &["memory", "stdout", "stderr", "stdin", "env",
                      "fs", "shell", "llm", "compute", "tts",
                      "exec", "web_tool"] {
            assert!(resource_type_for(kind).is_none(),
                "{} unexpectedly has a Terraform mapping", kind);
        }
    }

    #[test]
    fn unknown_kinds_yield_none() {
        assert!(resource_type_for("definitely_not_a_real_adapter").is_none());
    }
}
