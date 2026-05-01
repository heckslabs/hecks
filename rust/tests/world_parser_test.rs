//! World parser tests — pin the shapes the parity suite depends on.
//!
//! Covers both families: runtime/extension config (heki, ollama, …) and
//! strategic descriptors (purpose, vision, audience, concern).

use hecks_life::world_parser;

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
