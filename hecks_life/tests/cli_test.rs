//! CLI module tests
//!
//! Tests the command registry builder, ARGV parser, and help output.

use hecks_life::parser;
use hecks_life::cli;

const CLI_DOMAIN: &str = r#"Hecks.bluebook "HecksCli" do
  aggregate "ValidateCommand" do
    description "Check domain for DDD consistency"
    command "RunValidate" do
      role "Developer"
      attribute :domain_path
    end
  end
  aggregate "InspectCommand" do
    description "Full domain inspection with all details"
    command "RunInspect" do
      role "Developer"
      attribute :domain_path
      attribute :aggregate
    end
  end
  aggregate "TreeCommand" do
    description "Tree view of aggregates and commands"
    command "RunTree" do
      role "Developer"
      attribute :domain_path
    end
  end
  aggregate "BuildCommand" do
    description "Generate target code from domain"
    command "RunBuild" do
      role "Developer"
      attribute :domain_path
      attribute :target
    end
  end
end"#;

fn registry() -> Vec<cli::CommandEntry> {
    let domain = parser::parse(CLI_DOMAIN);
    cli::build_registry(&domain)
}

#[test]
fn builds_registry_from_domain() {
    let reg = registry();
    assert_eq!(reg.len(), 4);
    let names: Vec<&str> = reg.iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"validate"));
    assert!(names.contains(&"inspect"));
    assert!(names.contains(&"tree"));
    assert!(names.contains(&"build"));
}

#[test]
fn registry_strips_command_suffix() {
    let reg = registry();
    // "ValidateCommand" becomes "validate"
    assert!(reg.iter().any(|e| e.name == "validate"));
    // "BuildCommand" becomes "build"
    assert!(reg.iter().any(|e| e.name == "build"));
}

#[test]
fn registry_captures_description() {
    let reg = registry();
    let validate = reg.iter().find(|e| e.name == "validate").unwrap();
    assert_eq!(validate.description, "Check domain for DDD consistency");
}

#[test]
fn registry_captures_options() {
    let reg = registry();
    let inspect = reg.iter().find(|e| e.name == "inspect").unwrap();
    assert_eq!(inspect.options.len(), 2);
    let opt_names: Vec<&str> = inspect.options.iter().map(|o| o.name.as_str()).collect();
    assert!(opt_names.contains(&"domain_path"));
    assert!(opt_names.contains(&"aggregate"));
}

#[test]
fn parse_argv_simple() {
    let reg = registry();
    let argv: Vec<String> = vec!["validate".into(), "pizzas.bluebook".into()];
    let inv = cli::parse_argv(&argv, &reg).unwrap();
    assert_eq!(inv.command, "validate");
    assert_eq!(inv.args, vec!["pizzas.bluebook"]);
    assert!(inv.options.is_empty());
}

#[test]
fn parse_argv_with_options() {
    let reg = registry();
    let argv: Vec<String> = vec![
        "inspect".into(),
        "pizzas.bluebook".into(),
        "--aggregate".into(),
        "Pizza".into(),
    ];
    let inv = cli::parse_argv(&argv, &reg).unwrap();
    assert_eq!(inv.command, "inspect");
    assert_eq!(inv.args, vec!["pizzas.bluebook"]);
    assert_eq!(inv.options.get("aggregate").unwrap(), "Pizza");
}

#[test]
fn parse_argv_flag_without_value() {
    let reg = registry();
    let argv: Vec<String> = vec!["validate".into(), "--verbose".into()];
    let inv = cli::parse_argv(&argv, &reg).unwrap();
    assert_eq!(inv.options.get("verbose").unwrap(), "true");
}

#[test]
fn parse_argv_unknown_command() {
    let reg = registry();
    let argv: Vec<String> = vec!["bogus".into()];
    let err = cli::parse_argv(&argv, &reg);
    assert!(err.is_err());
    assert!(err.unwrap_err().contains("unknown command"));
}

#[test]
fn parse_argv_empty() {
    let reg = registry();
    let argv: Vec<String> = vec![];
    let err = cli::parse_argv(&argv, &reg);
    assert!(err.is_err());
    assert!(err.unwrap_err().contains("no command"));
}

#[test]
fn multi_word_command_name() {
    // "BuildCommand" -> "build", "GenerateConfigCommand" -> "generate_config"
    let domain = parser::parse(r#"Hecks.bluebook "T" do
  aggregate "GenerateConfigCommand" do
    description "Generate config"
    command "RunGenerateConfig" do
      role "Developer"
    end
  end
end"#);
    let reg = cli::build_registry(&domain);
    assert_eq!(reg.len(), 1);
    assert_eq!(reg[0].name, "generate_config");
}
