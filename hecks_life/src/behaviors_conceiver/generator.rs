//! Generator for behavioral test suites
//!
//! Walks a source domain's IR — every command, query, lifecycle
//! transition, and given clause becomes a `test` block. The archetype
//! suite informs density and style cues (verbose vs terse setups,
//! ordering) but the coverage is deterministic from the source IR.
//!
//! Output is a `_behavioral_tests.bluebook` text string. Round-trips
//! through both Ruby and Rust behaviors parsers (locked by the
//! existing parity contract).

use crate::behaviors_ir::TestSuite;
use crate::ir::{Aggregate, Command, Domain, Query, Transition};

/// Generate the full text of a `_behavioral_tests.bluebook` for `source`,
/// using `archetype` as a style/shape reference (currently informational).
pub fn generate_behaviors(source: &Domain, _archetype: Option<&TestSuite>) -> String {
    let mut out = String::new();
    out.push_str(&format!("Hecks.behaviors {:?} do\n", source.name));
    out.push_str(&format!(
        "  vision \"Behavioral tests for the {} domain — exercises every command and query in memory\"\n\n",
        source.name,
    ));

    for (i, agg) in source.aggregates.iter().enumerate() {
        if i > 0 { out.push('\n'); }
        out.push_str(&format!(
            "  # ── {} aggregate ──────────────────────────────────────────\n\n",
            agg.name,
        ));

        // One positive test per command.
        for cmd in &agg.commands {
            out.push_str(&command_test(agg, cmd));
            out.push('\n');
        }

        // One refused-variant test per given clause.
        for cmd in &agg.commands {
            for given in &cmd.givens {
                let msg = given.message.clone().unwrap_or_else(|| given.expression.clone());
                out.push_str(&refused_test(agg, cmd, &msg));
                out.push('\n');
            }
        }

        // One transition test per lifecycle transition.
        if let Some(lc) = &agg.lifecycle {
            for tr in &lc.transitions {
                out.push_str(&lifecycle_test(agg, lc.field.as_str(), tr));
                out.push('\n');
            }
        }

        // One count test per query.
        for q in &agg.queries {
            out.push_str(&query_test(agg, q));
            out.push('\n');
        }
    }

    out.push_str("end\n");
    out
}

fn command_test(agg: &Aggregate, cmd: &Command) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "  test \"{} sets {}\" do\n",
        cmd.name,
        attr_summary(cmd),
    ));
    s.push_str(&format!("    tests {:?}, on: {:?}\n", cmd.name, agg.name));
    if !cmd.attributes.is_empty() {
        s.push_str(&format!("    input  {}\n", kwargs_for_command(cmd)));
    }
    s.push_str(&format!("    expect {}\n", expect_for_command(cmd)));
    s.push_str("  end\n");
    s
}

fn refused_test(agg: &Aggregate, cmd: &Command, message: &str) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "  test \"{} refuses when {}\" do\n",
        cmd.name,
        truncate_phrase(message),
    ));
    s.push_str(&format!("    tests {:?}, on: {:?}\n", cmd.name, agg.name));
    if !cmd.attributes.is_empty() {
        s.push_str(&format!("    input  {}\n", kwargs_for_command(cmd)));
    }
    s.push_str(&format!("    expect refused: {:?}\n", message));
    s.push_str("  end\n");
    s
}

fn lifecycle_test(agg: &Aggregate, field: &str, tr: &Transition) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "  test \"{} transitions {} to {}\" do\n",
        tr.command, field, tr.to_state,
    ));
    s.push_str(&format!("    tests {:?}, on: {:?}\n", tr.command, agg.name));
    // If the transition has a from_state, set up a command that produces
    // that state. Heuristic: pick the first command in the aggregate.
    if let (Some(_from), Some(setup_cmd)) = (tr.from_state.as_deref(), agg.commands.first()) {
        if !cmd_eq(setup_cmd, &tr.command) {
            s.push_str(&format!("    setup  {:?}{}\n", setup_cmd.name, kwargs_inline(setup_cmd)));
        }
    }
    s.push_str(&format!("    expect {}: {:?}\n", field, tr.to_state));
    s.push_str("  end\n");
    s
}

fn query_test(agg: &Aggregate, q: &Query) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "  test \"{} returns matching records\" do\n",
        q.name,
    ));
    s.push_str(&format!("    tests {:?}, on: {:?}, kind: :query\n", q.name, agg.name));
    if let Some(setup_cmd) = agg.commands.iter().find(|c| !c.attributes.is_empty()) {
        s.push_str(&format!("    setup  {:?}{}\n", setup_cmd.name, kwargs_inline(setup_cmd)));
    }
    s.push_str("    expect count: 1\n");
    s.push_str("  end\n");
    s
}

// ─── helpers ─────────────────────────────────────────────────────────

fn cmd_eq(c: &Command, other_name: &str) -> bool { c.name == other_name }

fn attr_summary(cmd: &Command) -> String {
    if cmd.attributes.is_empty() { return "expected state".into(); }
    cmd.attributes.iter().map(|a| a.name.clone()).collect::<Vec<_>>().join(" + ")
}

fn kwargs_for_command(cmd: &Command) -> String {
    cmd.attributes.iter()
        .map(|a| format!("{}: {}", a.name, sample_value(&a.attr_type)))
        .collect::<Vec<_>>()
        .join(", ")
}

fn expect_for_command(cmd: &Command) -> String {
    if cmd.attributes.is_empty() {
        return "ok: \"true\"".into();
    }
    cmd.attributes.iter()
        .map(|a| format!("{}: {}", a.name, sample_value(&a.attr_type)))
        .collect::<Vec<_>>()
        .join(", ")
}

fn kwargs_inline(cmd: &Command) -> String {
    if cmd.attributes.is_empty() { return String::new(); }
    format!(", {}", kwargs_for_command(cmd))
}

/// A reasonable example value for a type, used for stub `input`/`expect`
/// kwargs. The author edits these by hand to match real intent — the
/// generator just has to make the file parse.
fn sample_value(t: &str) -> String {
    match t {
        "Integer" => "1".into(),
        "Float"   => "1.0".into(),
        "Boolean" => "\"true\"".into(),
        "String"  => "\"sample\"".into(),
        _         => format!("\"sample_{}\"", t.to_lowercase()),
    }
}

/// Trim a given-clause message into a short test-name fragment.
fn truncate_phrase(s: &str) -> String {
    let max = 40;
    if s.len() <= max { return s.into(); }
    format!("{}…", &s[..max])
}
