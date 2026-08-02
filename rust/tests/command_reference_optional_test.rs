//! `Command#reference_to`'s `optional:` — declared in `syntax.bluebook`
//! (`Command.reference_to`'s `optional` argument row), real on Ruby's
//! `CommandBuilder#reference_to(type, as: nil, optional: false)`, and never
//! read by Rust's parser until this pass: `reference_attribute` always built
//! `optional: false` regardless of what the line said, silently disagreeing
//! with a Ruby command that declared the argument optional. Unexercised by
//! the corpus — found by holding the parser to the same declaration that
//! `spec/syntax_conformance_spec.rb` already checks Ruby against.

use storehouse::parser;

fn find_command<'a>(domain: &'a storehouse::ir::Domain, aggregate: &str, command: &str) -> &'a storehouse::ir::Command {
    domain
        .aggregates
        .iter()
        .find(|a| a.name == aggregate)
        .and_then(|a| a.commands.iter().find(|c| c.name == command))
        .expect("the command under test")
}

fn attribute<'a>(command: &'a storehouse::ir::Command, name: &str) -> &'a storehouse::ir::Attribute {
    command.attributes.iter().find(|a| a.name == name).expect("the attribute under test")
}

const SOURCE: &str = "Hecks.bluebook \"Referring\" do\n  \
  aggregate \"Target\" do\n    identified_by { id.value }\n  end\n  \
  aggregate \"Thing\" do\n    identified_by { id.value }\n    \
    command \"Required\" do\n      role \"Someone\"\n      goal \"do it\"\n      \
      reference_to Target, as: :required_target\n      emits \"Done\"\n    end\n    \
    command \"Optional\" do\n      role \"Someone\"\n      goal \"do it\"\n      \
      reference_to Target, as: :maybe_target, optional: true\n      emits \"Done\"\n    end\n  \
  end\nend\n";

#[test]
fn a_command_reference_defaults_to_required() {
    let domain = parser::parse(SOURCE);
    let cmd = find_command(&domain, "Thing", "Required");
    assert!(!attribute(cmd, "required_target").optional);
}

#[test]
fn optional_true_on_a_command_reference_is_actually_read() {
    let domain = parser::parse(SOURCE);
    let cmd = find_command(&domain, "Thing", "Optional");
    assert!(attribute(cmd, "maybe_target").optional);
}
