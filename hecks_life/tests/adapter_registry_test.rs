//! Registry surface — tiny but pins the wiring the runtime expects.

use hecks_life::hecksagon_parser;
use hecks_life::runtime::adapter_registry::AdapterRegistry;

const SRC: &str = r#"Hecks.hecksagon "Tiny" do
  adapter :memory
  adapter :stdout
  adapter :shell, name: :ls, command: "ls", ok_exit: 0
  subscribe "Heartbeat"
end
"#;

#[test]
fn exposes_adapters_by_kind_and_name() {
    let hex = hecksagon_parser::parse(SRC);
    let reg = AdapterRegistry::from_hecksagon(hex);
    assert_eq!(reg.persistence(), Some("memory"));
    assert!(reg.io("stdout").is_some());
    assert!(reg.shell("ls").is_some());
    assert_eq!(reg.subscriptions(), &["Heartbeat".to_string()]);
    assert_eq!(reg.shell_names(), vec!["ls"]);
}

#[test]
fn empty_registry_has_no_adapters() {
    let reg = AdapterRegistry::empty("Blank");
    assert!(reg.shell("ls").is_none());
    assert!(reg.io("stdout").is_none());
    assert_eq!(reg.subscriptions().len(), 0);
}

#[test]
fn subscribers_for_finds_matching_on_events() {
    let src = r#"Hecks.hecksagon "Audit" do
  adapter :stdout, on :SessionStarted do end
end
"#;
    let hex = hecksagon_parser::parse(src);
    let reg = AdapterRegistry::from_hecksagon(hex);
    let subs = reg.subscribers_for("SessionStarted");
    assert_eq!(subs.len(), 1);
    assert!(reg.subscribers_for("NoSuchEvent").is_empty());
}
