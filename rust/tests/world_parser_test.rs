//! World parser tests — pin the shapes the parity suite depends on.
//!
//! [antibody-exempt: rust/tests/world_parser_test.rs — infrastructure test
//!  pinning the host-side .world parse shapes the parity suite depends on ;
//!  behaviours suites cannot exercise the .world parser. i728 added dormant
//!  persistence-strict coverage.]
//!
//! Covers both families: runtime/extension config (heki, ollama, …) and
//! strategic descriptors (purpose, vision, audience, concern).

use storehouse::world::parser as world_parser;

#[test]
fn persistence_strict_flag_parses_but_is_dormant() {
    // i728 — `persistence do strict true end` parses generically (no parser
    // change) and reads back as strict. Dormant : nothing enforces it yet.
    let strict = "Hecks.world \"Conception\" do\n  persistence do\n    strict true\n  end\nend\n";
    assert!(world_parser::parse(strict).persistence_strict(), "strict true → strict");

    // No persistence block → non-strict (the it-just-works default).
    let lax = "Hecks.world \"Adhoc\" do\nend\n";
    assert!(!world_parser::parse(lax).persistence_strict(), "no block → non-strict");

    // Explicit `strict false` → non-strict.
    let off = "Hecks.world \"Off\" do\n  persistence do\n    strict false\n  end\nend\n";
    assert!(!world_parser::parse(off).persistence_strict(), "strict false → non-strict");
}

const MIETTE: &str = r#"Hecks.world "Miette" do
  heki do
    dir "information"
  end

  ollama do
    model "bluebook-architect"
    url "http://localhost:11434"
  end
end
"#;

const DOMAIN_CONCEPTION: &str = r#"Hecks.world "DomainConception" do
  purpose "The rules for how a domain gets born"
  vision "Every domain is born complete"
  audience "Miette, Spring, Summer"

  concern "CompletenessAtBirth" do
    description "A domain without fixtures is stillborn"
  end

  concern "SelfVerification" do
    description "The conceived domain must test itself"
  end
end
"#;

#[test]
fn detects_world_source() {
    assert!(world_parser::is_world_source(MIETTE));
    assert!(world_parser::is_world_source(DOMAIN_CONCEPTION));
    assert!(!world_parser::is_world_source("Hecks.bluebook \"X\" do\nend"));
    assert!(!world_parser::is_world_source("Hecks.hecksagon \"X\" do\nend"));
}

#[test]
fn parses_family_a_runtime_config() {
    let w = world_parser::parse(MIETTE);
    assert_eq!(w.name, "Miette");
    assert_eq!(w.configs.len(), 2);

    let heki = w.config_for("heki").expect("heki block");
    assert_eq!(heki.get("dir"), Some("information"));

    let ollama = w.config_for("ollama").expect("ollama block");
    assert_eq!(ollama.get("model"), Some("bluebook-architect"));
    assert_eq!(ollama.get("url"), Some("http://localhost:11434"));
}

#[test]
fn parses_family_b_strategic_descriptors() {
    let w = world_parser::parse(DOMAIN_CONCEPTION);
    assert_eq!(w.name, "DomainConception");
    assert_eq!(w.purpose.as_deref(), Some("The rules for how a domain gets born"));
    assert_eq!(w.vision.as_deref(), Some("Every domain is born complete"));
    assert_eq!(w.audience.as_deref(), Some("Miette, Spring, Summer"));

    assert_eq!(w.concerns.len(), 2);
    assert_eq!(w.concerns[0].name, "CompletenessAtBirth");
    assert_eq!(
        w.concerns[0].description.as_deref(),
        Some("A domain without fixtures is stillborn")
    );
    assert_eq!(w.concerns[1].name, "SelfVerification");
}

#[test]
fn parses_empty_world() {
    let src = "Hecks.world \"EngineAdditives\" do\nend\n";
    let w = world_parser::parse(src);
    assert_eq!(w.name, "EngineAdditives");
    assert!(w.configs.is_empty());
    assert!(w.concerns.is_empty());
    assert!(w.purpose.is_none());
}

#[test]
fn parses_mcp_server_block() {
    let src = r#"Hecks.world "Tools" do
  mcp do
    server :gmail do
      token_env "MIETTE_GMAIL_ACCESS_TOKEN"
    end
  end
end
"#;
    let w = world_parser::parse(src);
    assert_eq!(w.name, "Tools");
    assert_eq!(w.servers.len(), 1);
    let gmail = w.server_for("gmail").expect("gmail server");
    assert_eq!(gmail.name, "gmail");
    assert_eq!(gmail.token_env.as_deref(), Some("MIETTE_GMAIL_ACCESS_TOKEN"));
    // server_for trims a leading colon, matching the adapter `server: :x` form.
    assert!(w.server_for(":gmail").is_some());
    // mcp block is not an extension config
    assert!(w.config_for("mcp").is_none());
}

#[test]
fn parses_inline_server_in_mcp_block() {
    // Inline `server ... end` line inside a multi-line mcp block, plus a
    // quoted (rather than symbol) server name + multiple servers.
    let src = r#"Hecks.world "Tools" do
  mcp do
    server :gdrive do; token_env "DRIVE_TOK" end
    server "linear" do
      token_env "LINEAR_TOK"
    end
  end
end
"#;
    let w = world_parser::parse(src);
    assert_eq!(w.servers.len(), 2);
    let gdrive = w.server_for("gdrive").expect("gdrive server");
    assert_eq!(gdrive.token_env.as_deref(), Some("DRIVE_TOK"));
    let linear = w.server_for("linear").expect("linear server");
    assert_eq!(linear.token_env.as_deref(), Some("LINEAR_TOK"));
}

#[test]
fn parses_int_and_array_values() {
    let src = r#"Hecks.world "App" do
  static_assets do
    port 4567
    views "views"
    content "views/**/*.html", "assets/**/*.js"
  end

  live_reload do
    debounce 0.5
  end
end
"#;
    let w = world_parser::parse(src);
    let sa = w.config_for("static_assets").unwrap();
    assert_eq!(sa.get("port"), Some("4567"));
    assert_eq!(sa.get("views"), Some("views"));
    // Multi-value key: we keep the raw tail text — consumers decide.
    let content = sa.get("content").unwrap();
    assert!(content.contains("views/**/*.html"));

    let lr = w.config_for("live_reload").unwrap();
    assert_eq!(lr.get("debounce"), Some("0.5"));
}

#[test]
fn parses_adapter_binding_block_form() {
    // Sprint 14 world-wires-real-adapters — top-level
    // `adapter "Name" do; key value end` parses into an AdapterBinding
    // on World. Presence of the binding IS the signal that wires this
    // adapter to a real backend ; the values carry the per-deployment
    // config (no `backend:` flag).
    let src = r#"Hecks.world "Deployment" do
  adapter "Shell" do
    output "real-ack"
    exit_code 7
  end
end
"#;
    let w = world_parser::parse(src);
    assert_eq!(w.adapter_bindings.len(), 1);
    let binding = w.adapter_binding_for("Shell").expect("Shell binding");
    assert_eq!(binding.name, "Shell");
    assert_eq!(binding.get("output"), Some("real-ack"));
    assert_eq!(binding.get("exit_code"), Some("7"));
    assert!(w.adapter_binding_for("Missing").is_none());
    // adapter binding is not an extension config
    assert!(w.config_for("adapter").is_none());
}

#[test]
fn parses_inline_adapter_binding() {
    // Sprint 14 — the inline form `adapter "X" do; key value end`
    // matches the same kv shape as the block form.
    let src = r#"Hecks.world "Deployment" do
  adapter "Shell" do; output "real-ack" end
end
"#;
    let w = world_parser::parse(src);
    let binding = w.adapter_binding_for("Shell").expect("inline binding");
    assert_eq!(binding.get("output"), Some("real-ack"));
}

#[test]
fn world_without_adapter_bindings_leaves_empty_vec() {
    // Sprint 14 — a world that declares no adapter bindings keeps the
    // vec empty so the resolver's lookup returns None and the canned
    // default fires for every driven adapter.
    let src = r#"Hecks.world "NoBindings" do
  purpose "runtime config only"
end
"#;
    let w = world_parser::parse(src);
    assert!(w.adapter_bindings.is_empty());
}
