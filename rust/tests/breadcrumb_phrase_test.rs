//! Statusline breadcrumb phrase format — i577.
//!
//! [antibody-exempt: rust/tests/breadcrumb_phrase_test.rs — kernel-floor
//!  test covering Runtime::format_breadcrumb_phrase, which lives in the
//!  antibody-exempt rust/src/runtime/mod.rs. The breadcrumb-rendering
//!  helper has no bluebook surface yet (statusline format is the
//!  rendering of the bus phrase ; the bluebook that owns the spec is
//!  yet to be conceived — i577 brief filed alongside).
//!  Inherits its parent module's exemption rationale.]
//!
//! The breadcrumb is the `🛠️ …` slot on the statusline ; one of
//! Miette's most-watched signals because it answers "what just
//! happened?" at a glance. Format locked 2026-05-12 by Chris :
//!
//!   `Domain::Aggregate.Command`   (commands, PascalCase)
//!   `Domain::Aggregate.query_name` (queries, snake_case)
//!
//! Two segments + dot. No entity slot in the path. The earlier
//! three-segment form (`Tools::Tools::Tools.Bash`) was rejected for
//! visible duplication.
//!
//! These tests cover the canonical shapes the spec calls out :
//! a root command on a same-named-as-bluebook aggregate (Tools.Bash) ;
//! a root command on a regular aggregate (Immunity.DetectThreat) ;
//! an entity-targeted command (Macrophage.Register — the entity slot
//! is not surfaced) ; and a bare-name dispatch that strips a `Context.`
//! prefix the caller passed in. Plus the fallback when the IR has no
//! matching aggregate (test doubles, synthetic events).

use storehouse::parser;
use storehouse::runtime::{CommandResult, Runtime};

fn boot(source: &str) -> Runtime {
    Runtime::boot(parser::parse(source))
}

fn result_for(agg: &str) -> CommandResult {
    CommandResult {
        aggregate_id: "1".to_string(),
        aggregate_type: agg.to_string(),
        event: None,
        deltas: Vec::new(),
    }
}

#[test]
fn tools_bash_renders_as_domain_aggregate_command() {
    // Tools bluebook has a single Tools aggregate ; root command Bash.
    // Domain = aggregate.context (the bluebook namespace "Tools").
    // Same-named bluebook + aggregate produces the canonical
    // duplication Chris called out : `Tools::Tools.Bash`.
    let rt = boot(r#"Hecks.bluebook "Tools" do
  aggregate "Tools" do
    description "Tool invocations"
    command "Bash" do
      role "Agent"
    end
  end
end"#);
    let phrase = rt.format_breadcrumb_phrase("Bash", &result_for("Tools"));
    assert_eq!(phrase, "Tools::Tools.Bash");
}

#[test]
fn entity_command_does_not_surface_entity_in_path() {
    // Macrophage bluebook with a Check entity owning Register. The
    // breadcrumb still renders the aggregate (Macrophage), NOT the
    // entity (Check) — the 2026-05-12 format correction retired the
    // entity slot. Shape Chris gave in the brief :
    // `Discipline::Macrophage.Run` (here the context is the bluebook,
    // and the entity's owning aggregate is the segment, not Check).
    let rt = boot(r#"Hecks.bluebook "Macrophage" do
  aggregate "Macrophage" do
    description "Live watcher"
    entity "Check" do
      attribute :name
      command "Register" do
        role "Macrophage"
        attribute :name
      end
    end
  end
end"#);
    let phrase = rt.format_breadcrumb_phrase("Register", &result_for("Macrophage"));
    assert_eq!(phrase, "Macrophage::Macrophage.Register");
}

#[test]
fn root_command_on_separate_named_aggregate() {
    // Immunity bluebook with an Immunity aggregate ; DetectThreat is a
    // root command. Same shape as Tools but exercises a different name
    // pair to guard against accidental aggregate==context coupling.
    let rt = boot(r#"Hecks.bluebook "Immunity" do
  aggregate "Immunity" do
    description "Antibody surveillance"
    command "DetectThreat" do
      role "Sentry"
    end
  end
end"#);
    let phrase = rt.format_breadcrumb_phrase("DetectThreat", &result_for("Immunity"));
    assert_eq!(phrase, "Immunity::Immunity.DetectThreat");
}

#[test]
fn qualified_dispatch_strips_context_prefix() {
    // Caller passed the full Context.Aggregate.Command form ; only the
    // bare `Command` segment should survive into the rendered phrase.
    // (rsplit('.').next() — the dispatcher's own bare-name extraction.)
    let rt = boot(r#"Hecks.bluebook "Tools" do
  aggregate "Tools" do
    description "Tools"
    command "Bash" do
      role "Agent"
    end
  end
end"#);
    let phrase = rt.format_breadcrumb_phrase("Tools.Tools.Bash", &result_for("Tools"));
    assert_eq!(phrase, "Tools::Tools.Bash");
}

#[test]
fn no_matching_aggregate_falls_back_to_aggregate_name() {
    // Synthetic dispatch : the IR has no aggregate matching the
    // result's type. Domain falls back to the merged Domain.category
    // when present, otherwise to the aggregate name — the phrase still
    // renders, the slot never empties.
    let rt = boot(r#"Hecks.bluebook "Other" do
  aggregate "Other" do
    description "Unrelated"
    command "Noop" do
      role "Test"
    end
  end
end"#);
    let phrase = rt.format_breadcrumb_phrase("MysteryCmd", &result_for("Unknown"));
    // No matching aggregate → domain falls back to aggregate_type ;
    // shape is `Unknown::Unknown.MysteryCmd`.
    assert_eq!(phrase, "Unknown::Unknown.MysteryCmd");
}
