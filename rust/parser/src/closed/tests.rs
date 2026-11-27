//! The closed form's own refusals, one per way a file could reach past the vocabulary.

use super::check;

fn bluebook(body: &str) -> String {
    format!("Hecks.bluebook \"Probe\" do\n  aggregate \"Order\" do\n{body}\n  end\nend\n")
}

fn refused(source: &str) -> String {
    match check("probe.bluebook", source) {
        Ok(text) => panic!("admitted:\n{text}"),
        Err(diagnostic) => diagnostic.to_string(),
    }
}

#[test]
fn a_closed_bluebook_comes_back_line_for_line_without_comments() {
    let source = bluebook(
        "    # the total\n    attribute :total, Integer,\n      default: 0\n    \
         given \"positive\" do\n      total >= 0\n    end",
    );
    let text = check("probe.bluebook", &source).expect("closed");
    assert_eq!(text.lines().count(), source.lines().count());
    assert!(text.contains("attribute :total, Integer, default: 0"));
    assert!(!text.contains('#'));
    assert_eq!(text.lines().nth(6), Some("total >= 0"));
}

#[test]
fn code_outside_a_declaration_is_refused() {
    let message = refused("system(\"id\")\nHecks.bluebook \"P\" do\nend\n");
    assert!(message.contains("probe.bluebook:1:"), "{message}");
    assert!(refused("require \"open3\"\n").contains("outside any declaration"));
    assert!(refused("ENV[\"X\"]\n").contains("outside any declaration"));
}

#[test]
fn code_inside_a_block_is_refused() {
    for line in [
        "    system(\"id\")",
        "    require \"open3\"",
        "    load \"x.rb\"",
        "    eval \"1\"",
        "    send :system, \"id\"",
        "    x = ENV[\"HOME\"]",
        "    File.read(\"/etc/passwd\")",
        "    %w[a b].each { |w| attribute w.to_sym, String }",
        "    3.times { attribute :x, String }",
        "    if true then attribute :x, String end",
        "    Hecks.bluebook \"Inner\" do end",
        "    QualityDials = 1",
    ] {
        let message = refused(&bluebook(line));
        assert!(message.contains("probe.bluebook:3"), "{line}: {message}");
    }
}

#[test]
fn an_argument_that_runs_code_is_refused() {
    for line in [
        "    attribute :x, String, default: ENV.fetch(\"X\")",
        "    attribute :x, Object.const_get(:String)",
        "    attribute :x, String, default: \"#{`id`}\"",
        "    description \"a\" if system(\"id\")",
        "    attribute :x, String; system(\"id\")",
        "    attribute :x, File",
    ] {
        assert!(refused(&bluebook(line)).contains("literals only"), "{line}");
    }
}

#[test]
fn a_rule_that_runs_code_is_refused() {
    for rule in [
        "ENV[\"X\"] == \"1\"",
        "File.read(\"/etc/passwd\").empty?",
        "Kernel.system(\"id\")",
        "send(:system, \"id\")",
        "`id`.empty?",
        "x.then { exit }",
        "@secret == 1",
        "$stdout.nil?",
        "instance_eval(\"1\")",
    ] {
        let source = bluebook(&format!("    given \"r\" do\n      {rule}\n    end"));
        assert!(refused(&source).contains("rule expression"), "{rule}");
    }
}

#[test]
fn a_hecksagon_bind_verb_is_open_but_never_a_ruby_method() {
    let ok = "Hecks.hecksagon \"P\" do\n  persisted_by \"Heki\"\n  Probe::Order.persisted_by \
              \"Memory\"\n  Probe::Order.port \"Feed\" do\n  end\nend\n";
    assert!(check("p.hecksagon", ok).is_ok());
    for line in [
        "  system \"id\"",
        "  instance_eval \"1\"",
        "  Probe::Order.send :x",
    ] {
        let source = format!("Hecks.hecksagon \"P\" do\n{line}\nend\n");
        let message = match check("p.hecksagon", &source) {
            Ok(_) => panic!("admitted {line}"),
            Err(diagnostic) => diagnostic.to_string(),
        };
        assert!(message.contains("Ruby method"), "{line}: {message}");
    }
}

#[test]
fn a_loop_that_builds_words_is_refused() {
    let source = "Hecks.hecksagon \"P\" do\n  %w[A B].each do |name|\n    persisted_by name\n  \
                  end\nend\n";
    assert!(check("p.hecksagon", source).is_err());
}

#[test]
fn a_world_binding_is_open_but_its_values_are_literals() {
    let ok =
        "Hecks.world \"P\" do\n  realm \"local\"\n  heki do\n    dir \"tmp/heki\"\n  end\nend\n";
    assert!(check("p.world", ok).is_ok());
    let home = "Hecks.world \"P\" do\n  heki do\n    dir File.expand_path(\"~/.x\")\n  end\nend\n";
    assert!(check("p.world", home).is_err());
    let exit = "Hecks.world \"P\" do\n  exit\nend\n";
    assert!(check("p.world", exit).is_err());
}
