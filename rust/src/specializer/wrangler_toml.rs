//! Cloudflare `wrangler.toml` emitter — the fifth member of the
//! `:codegen` deploy-artifact family, sibling to wasm_worker (the
//! Worker crate), embedded_bluebooks (the compiled-in bluebook tree),
//! and cf_function_proxy (the Pages Function in front of it).
//!
//! Reads a deployment's `cloudflare.bluebook` (the `WorkerConfig`
//! fixture) and emits the matching `wrangler.toml` so the toml is
//! DERIVED, not hand-synced. The bluebook is the source of truth ; the
//! toml is the artifact (the way the Procfile derives from mindstream).
//! Shape declared in codegen/wrangler_toml_shape/. Per-deployment
//! emitter : it reads a fixture from an app's bluebook, not a tracked
//! rust/src/*.rs file, so it has no arm in the generic
//! specializer::emit() byte-identity dispatch — it is driven by
//! `storehouse specialize wrangler_toml --config <bluebook> --output
//! <wrangler.toml>`.
//!
//! The emitted toml carries exactly the WorkerConfig fixture's values :
//! name / main / compatibility_date, the `[[r2_buckets]]` heki→R2
//! binding (only when r2_binding + r2_bucket are non-empty), the
//! `[build]` command, and `[observability]` enabled when the fixture's
//! observability field is "enabled". Re-runs against the same bluebook
//! produce byte-identical output.

use crate::parse_blocks::parse_fixture_block_body;

/// One Cloudflare Worker's deploy configuration, read from the
/// `WorkerConfig` fixture inside a `cloudflare.bluebook`. Field names
/// mirror the fixture's attribute keys.
#[derive(Debug, Default, Clone)]
pub struct WorkerConfigFields {
    pub name: String,
    pub compatibility_date: String,
    pub main_entrypoint: String,
    pub build_command: String,
    pub r2_binding: String,
    pub r2_bucket: String,
    pub observability: String,
}

/// Read the first `fixture "<label>", on: "WorkerConfig" do … end` block
/// out of a bluebook source string and project it onto WorkerConfigFields.
///
/// The block-form fixture body is parsed by the shared
/// `parse_blocks::parse_fixture_block_body` (the same reader the bluebook
/// IR parser uses), so `name "x"` lines become (key, value) pairs.
/// Returns None when the bluebook carries no WorkerConfig fixture.
pub fn read_worker_config(source: &str) -> Option<WorkerConfigFields> {
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i].trim();
        // Block-form fixture opener : `fixture "Label", on: "WorkerConfig" do`.
        // The aggregate is named by the `on:` kwarg on the opener line (the
        // block body carries `key "value"` attribute lines, no inner
        // `aggregate "X"` line), so we match on `on: "WorkerConfig"` rather
        // than trusting parse_fixture_block_body's aggregate-name slot.
        if l.starts_with("fixture ")
            && l.ends_with(" do")
            && l.contains("on:")
            && l.contains("\"WorkerConfig\"")
        {
            let (_agg, attrs, _consumed) = parse_fixture_block_body(&lines[i + 1..]);
            return Some(project(&attrs));
        }
        i += 1;
    }
    None
}

/// Project a fixture's (key, value) attribute pairs onto the typed
/// WorkerConfigFields. Unknown keys are ignored ; missing keys keep
/// their Default (empty string).
fn project(attrs: &[(String, String)]) -> WorkerConfigFields {
    let mut cfg = WorkerConfigFields::default();
    for (key, value) in attrs {
        match key.as_str() {
            "name" => cfg.name = value.clone(),
            "compatibility_date" => cfg.compatibility_date = value.clone(),
            "main_entrypoint" => cfg.main_entrypoint = value.clone(),
            "build_command" => cfg.build_command = value.clone(),
            "r2_binding" => cfg.r2_binding = value.clone(),
            "r2_bucket" => cfg.r2_bucket = value.clone(),
            "observability" => cfg.observability = value.clone(),
            _ => {}
        }
    }
    cfg
}

/// Render the `wrangler.toml` body from a WorkerConfigFields.
///
/// Layout : a generated-from header, the three top-level keys (name,
/// main, compatibility_date), an optional `[[r2_buckets]]` block (only
/// when both r2_binding and r2_bucket are present), the `[build]`
/// command, and `[observability]` (enabled iff the field reads
/// "enabled").
pub fn emit_wrangler_toml(cfg: &WorkerConfigFields) -> String {
    let mut out = String::new();
    out.push_str(
        "# DERIVED from ../cloudflare.bluebook (the WorkerConfig fixture)\n\
         # by `storehouse specialize wrangler_toml`. The bluebook is the\n\
         # source of truth ; this file is the artifact. Do not hand-edit —\n\
         # change the fixture and regenerate.\n\n",
    );
    out.push_str(&format!("name               = \"{}\"\n", cfg.name));
    out.push_str(&format!("main               = \"{}\"\n", cfg.main_entrypoint));
    out.push_str(&format!(
        "compatibility_date = \"{}\"\n",
        cfg.compatibility_date
    ));

    if !cfg.r2_binding.is_empty() && !cfg.r2_bucket.is_empty() {
        out.push_str("\n# heki -> R2 persistence binding. lib.rs reads this binding by\n");
        out.push_str("# name to hydrate state on boot and persist every dispatch back.\n");
        out.push_str("[[r2_buckets]]\n");
        out.push_str(&format!("binding     = \"{}\"\n", cfg.r2_binding));
        out.push_str(&format!("bucket_name = \"{}\"\n", cfg.r2_bucket));
    }

    out.push_str("\n[build]\n");
    out.push_str(&format!("command = \"{}\"\n", cfg.build_command));

    if cfg.observability == "enabled" {
        out.push_str("\n[observability]\nenabled = true\n");
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
Hecks.bluebook "DailyMusingCloudflare", version: "1" do
  fixture "DailyMusingWorker", on: "WorkerConfig" do
    name               "daily-musing-worker"
    compatibility_date "2026-05-10"
    account_id         "d64266851dc554da77687e13c058917c"
    main_entrypoint    "build/worker/shim.mjs"
    build_command      "cargo install -q worker-build && worker-build --release"
    r2_binding         "DAILY_MUSING_R2_BUCKET"
    r2_bucket          "daily-musing-heki"
    observability      "enabled"
  end
end
"#;

    #[test]
    fn reads_worker_config_fixture() {
        let cfg = read_worker_config(SAMPLE).expect("WorkerConfig fixture");
        assert_eq!(cfg.name, "daily-musing-worker");
        assert_eq!(cfg.compatibility_date, "2026-05-10");
        assert_eq!(cfg.main_entrypoint, "build/worker/shim.mjs");
        assert_eq!(cfg.r2_binding, "DAILY_MUSING_R2_BUCKET");
        assert_eq!(cfg.r2_bucket, "daily-musing-heki");
        assert_eq!(cfg.observability, "enabled");
    }

    #[test]
    fn emits_top_level_keys_and_r2_block() {
        let cfg = read_worker_config(SAMPLE).unwrap();
        let toml = emit_wrangler_toml(&cfg);
        assert!(toml.contains("name               = \"daily-musing-worker\""));
        assert!(toml.contains("main               = \"build/worker/shim.mjs\""));
        assert!(toml.contains("compatibility_date = \"2026-05-10\""));
        assert!(toml.contains("[[r2_buckets]]"));
        assert!(toml.contains("binding     = \"DAILY_MUSING_R2_BUCKET\""));
        assert!(toml.contains("bucket_name = \"daily-musing-heki\""));
        assert!(toml.contains("[build]"));
        assert!(toml.contains("command = \"cargo install -q worker-build && worker-build --release\""));
        assert!(toml.contains("[observability]\nenabled = true"));
    }

    #[test]
    fn omits_r2_block_when_binding_absent() {
        let mut cfg = read_worker_config(SAMPLE).unwrap();
        cfg.r2_binding = String::new();
        cfg.r2_bucket = String::new();
        let toml = emit_wrangler_toml(&cfg);
        assert!(!toml.contains("[[r2_buckets]]"));
    }

    #[test]
    fn omits_observability_when_not_enabled() {
        let mut cfg = read_worker_config(SAMPLE).unwrap();
        cfg.observability = String::new();
        let toml = emit_wrangler_toml(&cfg);
        assert!(!toml.contains("[observability]"));
    }

    #[test]
    fn no_worker_config_returns_none() {
        assert!(read_worker_config("Hecks.bluebook \"X\", version: \"1\" do\nend\n").is_none());
    }
}
