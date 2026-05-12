//! Rust-native specializer for `rust/src/main.rs`.
//!
//! i147 Wave 6 target — the CLI entry-point, regenerated from the
//! `cli_dispatch_shape` bluebook + ordered Section / Subcommand /
//! HelpRow rows + per-section / per-arm `.rs.frag` snippets.
//!
//! Design — three-aggregate shape with body_kind dispatch :
//!
//!   Section  — ordered top-level partitions of main.rs. body_kind
//!              picks the emitter :
//!                verbatim_section — read snippet_path raw, emit
//!                                   unchanged.
//!                dispatch_chain   — synthetic ; concatenate
//!                                   Subcommand snippets in `order`
//!                                   ascending.
//!                usage_help       — synthetic ; emit print_usage with
//!                                   Commands: list assembled from
//!                                   HelpRow rows in `order` ascending.
//!
//!   Subcommand — one row per arm in fn main()'s if-chain. Each row's
//!                snippet carries the arm body verbatim (leading blank
//!                + leading comment block + the
//!                `if command == "X" { ... return; }` block).
//!
//!   HelpRow    — one row per command in print_usage's Commands: list.
//!                Decoupled from Subcommand because the help listing
//!                curates a different ordering AND includes match-arm
//!                commands (parse, validate, inspect, tree, list, serve,
//!                hydrate) that never appear in the if-chain.
//!
//! Real compression : the dispatch ROUTING contract — the ORDER of
//! subcommands in the if-chain plus the help listing — is now data,
//! not Rust code. Adding a new CLI subcommand is a single fixture row
//! plus a per-arm snippet, no main.rs hand-edit.
//!
//! Usage :
//!   let rust = cli_dispatch::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/cli_dispatch.rs —
//!  i147 Wave 6 Rust-native specializer for main.rs's dispatch chain.
//!  Retires when the specializer itself is regenerated from a
//!  meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/cli_dispatch_shape/fixtures/cli_dispatch_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    for sec in &sections {
        match util::attr(sec, "body_kind") {
            "verbatim_section" => {
                let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "dispatch_chain" => {
                out.push_str(&emit_dispatch_chain(repo_root, &fixtures)?);
            }
            "usage_help" => {
                out.push_str(&emit_usage_help(&fixtures));
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit the if-chain by concatenating Subcommand snippets in `order`
/// ascending. Each snippet carries its leading blank-line separator
/// inline (the first arm's snippet's leading blank is the separator
/// from the prior section's trailing close brace).
fn emit_dispatch_chain(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let arms = util::by_aggregate_sorted(fixtures, "Subcommand", "order");

    let mut out = String::new();
    for arm in &arms {
        let snippet_path = repo_root.join(util::attr(arm, "snippet_path"));
        let body = util::read_snippet_raw(&snippet_path)?;
        out.push_str(&body);
    }
    Ok(out)
}

/// Emit the print_usage function. The prelude (signature, banner,
/// Usage line, "Commands:" header) and the trailing blocks (Heki
/// subcommands, Options, closing brace) are hardcoded ; the per-row
/// Commands: list comes from HelpRow fixtures.
fn emit_usage_help(fixtures: &[Fixture]) -> String {
    let rows = util::by_aggregate_sorted(fixtures, "HelpRow", "order");

    let mut out = String::new();
    out.push_str("fn print_usage() {\n");
    out.push_str("    eprintln!(\"storehouse — the Bluebook compiler and runtime\\n\");\n");
    out.push_str("    eprintln!(\"Usage: storehouse <command> <bluebook-file> [options]\\n\");\n");
    out.push_str("    eprintln!(\"Commands:\");\n");
    for row in &rows {
        let command = util::attr(row, "command");
        let description = util::attr(row, "description");
        let padded_width = util::attr(row, "padded_width")
            .parse::<usize>()
            .unwrap_or(11);
        let trailing_newline = util::attr(row, "trailing_newline") == "yes";
        let cmd_len = command.len();
        // padded_width is the total column width of the command field
        // INCLUDING the trailing space(s) before the description. For
        // most rows : command (n chars) + (padded_width - n) spaces +
        // description. The 1-space gap between the last command char
        // and the description is provided by the padding, not an
        // explicit literal space.
        let pad = padded_width.saturating_sub(cmd_len);
        let suffix = if trailing_newline { "\\n" } else { "" };
        out.push_str(&format!(
            "    eprintln!(\"  {}{}{}{}\");\n",
            command,
            " ".repeat(pad),
            description,
            suffix,
        ));
    }
    out.push_str("    eprintln!(\"Heki subcommands:\");\n");
    out.push_str("    eprintln!(\"  heki read   <file>           Dump store as JSON\");\n");
    out.push_str("    eprintln!(\"  heki latest <file>           Show latest record\");\n");
    out.push_str("    eprintln!(\"  heki append <file> k=v ...   Append new record\");\n");
    out.push_str("    eprintln!(\"  heki upsert <file> k=v ...   Upsert singleton\");\n");
    out.push_str("    eprintln!(\"  heki delete <file> <id>      Delete record by ID\\n\");\n");
    out.push_str("    eprintln!(\"Options:\");\n");
    out.push_str("    eprintln!(\"  --seed <file>      Load seed commands at boot (run/serve)\");\n");
    out.push_str("    eprintln!(\"  --corpus <dirs>    Corpus directories (conceive/develop)\");\n");
    out.push_str("    eprintln!(\"  --add <feature>    Feature to add (develop)\");\n");
    out.push_str("    eprintln!(\"  --from <path>      Source archetype bluebook (develop)\");\n");
    out.push_str("}\n");
    out
}

const HEADER: &str = r#"//! Hecks Life — the Bluebook compiler and runtime
//!
//! Reads .bluebook files, parses them into IR, and executes them.
//! The Bluebook is DNA. This is the ribosome. The runtime is life.
//!
//! [antibody-exempt: rust/src/main.rs — wires the :llm hecksagon
//!  adapter into dispatch_hecksagon. This IS the structural rewrite
//!  that lets wake_review and interpret_dream fire end-to-end via
//!  bluebook. Same i80 retirement contract ; closes the i109 :llm
//!  runtime gap that PR #455 explicitly named. Rewriting IS the work.]
//!
//! Usage:
//!   storehouse parse     pizzas.bluebook
//!   storehouse validate  pizzas.bluebook
//!   storehouse inspect   pizzas.bluebook
//!   storehouse tree      pizzas.bluebook
//!   storehouse list      pizzas.bluebook
//!   storehouse run       pizzas.bluebook [--seed seeds.txt]
//!   storehouse serve     pizzas.bluebook [--seed seeds.txt] [port]
//!   storehouse serve     path/to/hecks/ [port]
//!   storehouse conceive  "Name" "vision" --corpus dir1 dir2
//!   storehouse develop   target.bluebook --add "feature"
//!
//! [antibody-exempt: rust/src/main.rs — wires validator_warnings into
//!  dispatch arms. This IS the structural rewrite that closes the gap
//!  between the bluebook-declared rules (capabilities/validator_warnings_shape/)
//!  and runtime enforcement. Same i80 retirement contract as run_loop /
//!  run_daemon / run_macrophage. Net ~12 LoC.]
//!
//! [antibody-exempt: rust/src/main.rs — closes i113 (sleep-as-blocking-
//!  streaming-command). Wires Consciousness.EnterSleep dispatch + heki polling
//!  + dream stream + wake-report read into a single blocking CLI. Same kernel-
//!  surface family as run_loop / run_daemon / run_macrophage ; same i80
//!  retirement contract — retires once cli.bluebook lands and CLI routing
//!  becomes declarative.]
//!
//! [antibody-exempt: rust/src/main.rs — closes i118 (macrophage-honors-
//!  in-file-antibody-exempt-markers). run_macrophage now reads the touched
//!  file's first 200 lines and dispatches Macrophage.RecordExemptedEdit (silent
//!  exit 0) instead of Macrophage.Complain when the file already carries a
//!  marker. The marker IS the audit trail. Same i80 retirement contract as
//!  the rest of the run_macrophage family.]
//!
//! [antibody-exempt: rust/src/main.rs detect_bash_write_target +
//!  scan_command_with_path_arg — 2026-05-02 false-positive heal. The prior
//!  classifier treated `sed -n '...'` (autoprint-suppress, read-only) as a
//!  write target whenever any flag was present, blocking honest reads of
//!  .rs files. New shape : each cmd_name names the exact write signatures
//!  (None for tee/always-write ; Some(&[bigrams]) for sed -i / --in-place
//!  and awk -i inplace). Same i80 retirement contract as the rest of the
//!  run_macrophage family — retires when the macrophage's command-string
//!  classification becomes a domain dispatched from
//!  aggregates/discipline/macrophage/.]
//!
//! [antibody-exempt: rust/src/main.rs — i117 Round 4. load_combined_domain
//!  walks the sibling ../miette repo as an additional bluebook root at depth 1.
//!  Miette's self/mind/body/library/surface aggregates physically live in
//!  chrisyoung/miette post-split ; the runtime needs to find them for the same
//!  dispatch domain that scans hecks_conception/aggregates/. The pre-push
//!  behaviors gate (tooling/git-hooks/pre-push) has scanned this root for
//!  weeks ; the runtime now matches. Skipped silently when the sibling repo
//!  isn't checked out (CI running on hecks alone keeps working). Retires
//!  alongside the broader i118 hecks/miette reshape.]

use storehouse::{parser, validator, validator_warnings, server, conceiver, heki, heki_query, dump,
                 behaviors_parser, behaviors_dump};
use storehouse::runtime::Runtime;

use std::env;
use std::fs;
"#;
