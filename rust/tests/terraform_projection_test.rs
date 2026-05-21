//! Terraform projection tests — pin the HCL contract via goldens.
//!
//! Bluebook contract :
//!   hecks_conception/aggregates/framework/projection/terraform.bluebook
//!
//! Fixture set lives at rust/tests/fixtures/terraform_projection/ —
//! one `.hecksagon` + `.world` + `.tf.golden` triple per scenario.
//! When the projection logic changes, the goldens move WITH the
//! intent, not as a drive-by.

use storehouse::{hecksagon_parser, projection, world_parser};

const FIXTURE_DIR: &str = "tests/fixtures/terraform_projection";

fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {}", path, e))
}

#[test]
fn projects_three_adapter_hecksagon_against_golden() {
    let hex_src = read(&format!("{}/events.hecksagon", FIXTURE_DIR));
    let world_src = read(&format!("{}/events.world", FIXTURE_DIR));
    let golden = read(&format!("{}/events.tf.golden", FIXTURE_DIR));

    let hex = hecksagon_parser::parse(&hex_src);
    let world = world_parser::parse(&world_src);

    let result = projection::terraform::project_hecksagon(&hex, Some(&world));

    assert_eq!(
        result.hcl, golden,
        "HCL output drifted from golden — diff intent before updating fixture"
    );
    assert_eq!(result.adapter_count, 3, "expected 3 resources (sqs/lambda/s3)");
}

#[test]
fn projection_without_world_uses_inline_options_only() {
    let hex_src = r#"Hecks.hecksagon "Standalone" do
  adapter :memory
  adapter :s3, name: "logs", versioning: "enabled"
end
"#;
    let hex = hecksagon_parser::parse(hex_src);
    let result = projection::terraform::project_hecksagon(&hex, None);
    assert_eq!(result.adapter_count, 1);
    // No provider block (no world) — straight to the resource.
    assert!(result.hcl.contains("resource \"aws_s3_bucket\" \"logs\""));
    assert!(result.hcl.contains("versioning = \"enabled\""));
    assert!(!result.hcl.contains("provider \"aws\""));
}

#[test]
fn skips_adapters_without_cloud_mapping() {
    // :memory + :stdout + :tts have no Terraform mapping. The
    // projector silently skips them ; adapter_count reflects only
    // the resources that actually emit.
    let hex_src = r#"Hecks.hecksagon "Mixed" do
  adapter :memory
  adapter :stdout
  adapter :tts, name: :voice, provider: :elevenlabs, trigger_on: "X.Y"
  adapter :s3, name: "logs"
end
"#;
    let hex = hecksagon_parser::parse(hex_src);
    let result = projection::terraform::project_hecksagon(&hex, None);
    assert_eq!(result.adapter_count, 1, "only :s3 maps to a cloud resource");
    assert!(result.hcl.contains("aws_s3_bucket"));
    assert!(!result.hcl.contains("aws_lambda_function"));
}

#[test]
fn world_values_override_inline_options() {
    let hex_src = r#"Hecks.hecksagon "Override" do
  adapter :memory
  adapter :sqs, name: "q", visibility_timeout: 30
end
"#;
    let world_src = r#"Hecks.world "Override" do
  q do
    visibility_timeout 90
  end
end
"#;
    let hex = hecksagon_parser::parse(hex_src);
    let world = world_parser::parse(world_src);
    let result = projection::terraform::project_hecksagon(&hex, Some(&world));
    // World's 90 wins over inline's 30. The value appears bare (HCL
    // number literal) because format_value parses it as i64.
    assert!(result.hcl.contains("visibility_timeout = 90"));
    assert!(!result.hcl.contains("visibility_timeout = 30"));
}

#[test]
fn project_adapter_returns_single_resource_block() {
    let inline: Vec<(String, String)> = vec![
        ("name".into(),       "\"x\"".into()),
        ("versioning".into(), "\"enabled\"".into()),
    ];
    let world: Vec<(String, String)> = vec![
        ("bucket".into(), "my-bucket".into()),
    ];
    let block = projection::terraform::project_adapter("s3", "x", &inline, &world)
        .expect("s3 must project");
    assert!(block.starts_with("resource \"aws_s3_bucket\" \"x\""));
    assert!(block.contains("bucket"));
    assert!(block.contains("versioning"));
    // No `name = ...` line — name is the resource id, not a property.
    assert!(!block.contains("name        ="));
    assert!(!block.contains("name ="));
}

#[test]
fn project_adapter_returns_none_for_unmapped_kind() {
    let inline: Vec<(String, String)> = vec![("name".into(), "\"x\"".into())];
    assert!(projection::terraform::project_adapter("memory", "x", &inline, &[]).is_none());
    assert!(projection::terraform::project_adapter("tts",    "x", &inline, &[]).is_none());
}
