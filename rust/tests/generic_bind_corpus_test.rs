// Exercises `bluebook::generic_bind`/`parser` directly — not compiled at
// all without the `parser` feature.
#![cfg(feature = "parser")]

//! CORPUS-WIDE DIFFERENTIAL SMOKE CHECK for the generic argument binder
//! (`storehouse::bluebook::generic_bind::bind_keyword`).
//!
//! WHAT THIS PROVES, AND WHAT IT DOES NOT. The binder does not yet build a
//! whole `Domain` the way `parser::parse` does — it binds ONE LINE at a
//! time, against a `KeywordBinding` already resolved to the right context.
//! A true field-for-field comparison against `parser::parse`'s own output
//! needs the hand-written `parse_X` functions to actually CALL the binder
//! (the next milestone), at which point the existing full test + `bin/
//! parity` suite already proves exact equality end to end — that is a
//! stronger check than anything this file could build standalone, and
//! duplicating it here would be a second, weaker oracle.
//!
//! What THIS file proves, ahead of any cutover : walking EVERY real corpus
//! `.bluebook` file (examples/**/*.bluebook, spec/fixtures/**/*.bluebook),
//! tracking context with the SAME `ir_dispatch_words` tables the real
//! parser's own `dispatch_block`/`parse_aggregate`/... already dispatch on
//! (so "what context is this line in" is never a second guess), every line
//! whose keyword has a generated `KeywordBinding` for that context binds
//! WITHOUT PANICKING, and every `required: true` argument that the real
//! parser would also require produces a binding. A crash or a silently
//! missing required field here is a real defect in the binder, caught
//! against real corpus text before any hand-written code is touched.
use std::fs;
use std::path::{Path, PathBuf};

use storehouse::bluebook::generic_bind::bind_keyword;
use storehouse::bluebook::ir_dispatch_words as words;
use storehouse::bluebook::ir_syntax_bindings::KEYWORD_BINDINGS;

fn corpus_files() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for root in ["../examples", "../spec/fixtures"] {
        collect_bluebooks(Path::new(root), &mut out);
    }
    assert!(!out.is_empty(), "no corpus .bluebook files found — check the search roots");
    out
}

fn collect_bluebooks(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_bluebooks(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "bluebook") {
            out.push(path);
        }
    }
}

/// A line starts with `word` as its OWN token, not merely as a text prefix
/// (`sets` must not match `settle`) — the same guard `parser::keyword_matches`
/// enforces, reimplemented here rather than reached for : that function is
/// `pub(crate)`, invisible across the integration-test crate boundary, and
/// the check itself is three lines, not worth widening real-code visibility
/// for a test file to borrow once.
fn starts_with_word(line: &str, word: &str) -> bool {
    let Some(rest) = line.strip_prefix(word) else { return false };
    rest.is_empty() || !rest.chars().next().is_some_and(|c| c.is_alphanumeric() || c == '_')
}

/// WHICH CATEGORY A LINE OPENS, IN THE CURRENT CONTEXT — every
/// `ir_dispatch_words` table this crate already generates, plus the two
/// pseudo-contexts (`Lifecycle`, `OneOf`) that table's own source
/// (`Syntax::Keyword`, rows where `opens` is not empty) also names but
/// which `bin/ir_dispatch_words` does not currently emit tables for.
fn opens(context: &str, line: &str) -> Option<&'static str> {
    // `Hecks.bluebook "X" do` is the one transition `ir_dispatch_words` does
    // not table — `parser.rs`'s own `parse()` special-cases it the same way
    // (a direct `line.starts_with("Hecks.bluebook")` check, not a
    // `dispatch_block` table lookup), since it is reached through the
    // `Hecks` receiver rather than an enclosing builder.
    if context == "File" && line.starts_with("Hecks.bluebook") {
        return Some("Bluebook");
    }
    let table: &[(&str, &str)] = match context {
        "Bluebook" => words::BLUEBOOK_WORDS,
        "Aggregate" => words::AGGREGATE_WORDS,
        "Entity" => words::ENTITY_WORDS,
        "ProcessManager" => words::PROCESS_MANAGER_WORDS,
        "Handler" => words::HANDLER_WORDS,
        _ => return None,
    };
    table.iter().find(|(word, _)| starts_with_word(line, word)).map(|(_, opens)| *opens)
}

fn ends_with_do(line: &str) -> bool {
    line.trim_end().ends_with("do")
}

/// A LINE'S OWN CONTEXT-LOCAL BINDING TABLE, if `Syntax::Keyword`/
/// `Syntax::Argument` declare one for this (word, context) — the same join
/// `bind_keyword`'s caller is expected to have already resolved before
/// calling it (this file's whole job is resolving it, the way a real
/// `parse_X` cutover eventually will).
fn binding_for<'a>(context: &str, line: &str) -> Option<&'a storehouse::bluebook::ir_syntax_bindings::KeywordBinding> {
    KEYWORD_BINDINGS.iter().find(|b| b.context == context && starts_with_word(line, b.keyword))
}

struct Walk {
    checked: usize,
    missing_required: Vec<String>,
}

fn walk_file(path: &Path, walk: &mut Walk) {
    let source = fs::read_to_string(path).unwrap_or_default();
    // A malformed or deliberately-broken fuzz/escape fixture is not this
    // file's concern — only well-formed corpus text is.
    if source.trim().is_empty() {
        return;
    }

    let mut stack: Vec<String> = vec!["File".to_string()];
    // `Lifecycle`/`OneOf` bodies are opened by words no `ir_dispatch_words`
    // table carries (see `opens`'s own comment) — tracked by literal match
    // here, same spirit as that function's fallback.
    for raw in source.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line == "end" {
            if stack.len() > 1 {
                stack.pop();
            }
            continue;
        }

        let context = stack.last().cloned().unwrap_or_else(|| "File".to_string());

        if let Some(binding) = binding_for(&context, line) {
            walk.checked += 1;
            let bindings = bind_keyword(binding, line);

            let bound = |arg: &storehouse::bluebook::ir_syntax_bindings::ArgumentBinding| {
                if arg.kind == "pairs" {
                    bindings.pairs.contains_key(arg.named)
                } else if !arg.fills.is_empty() {
                    bindings.fields.contains_key(arg.fills)
                } else {
                    // Fills nothing and is not pairs (the `Type`-context
                    // rows) — nothing this walker can check presence of.
                    true
                }
            };

            // A SLOT, NOT A ROW. Two rows can share one (at, named) slot
            // with different `kind`s admitting either spelling (`on`'s
            // event_type — text or the `:refused` symbol) — only ONE of
            // them binds for any real line, by design (`bind_scalar`'s own
            // kind-matching guards), so `required` is checked per SLOT : it
            // is satisfied the moment ANY row sharing that slot binds, even
            // if this particular row's own kind is not the one that did.
            for arg in binding.arguments {
                if !arg.required {
                    continue;
                }
                let slot_satisfied = binding
                    .arguments
                    .iter()
                    .any(|candidate| candidate.at == arg.at && candidate.named == arg.named && bound(candidate));
                if !slot_satisfied {
                    walk.missing_required.push(format!(
                        "{}: {:?} — required {} ({} {:?}) produced no binding from any row sharing its slot",
                        path.display(),
                        line,
                        binding.keyword,
                        if arg.at.is_empty() { "named" } else { "at" },
                        if arg.at.is_empty() { arg.named } else { arg.at },
                    ));
                }
            }
        }

        if ends_with_do(line) {
            let next = opens(&context, line)
                .or_else(|| if starts_with_word(line, "lifecycle") { Some("Lifecycle") } else { None })
                .or_else(|| if starts_with_word(line, "one_of") { Some("OneOf") } else { None })
                .unwrap_or("Unknown");
            stack.push(next.to_string());
        }
    }
}

#[test]
fn every_covered_keyword_binds_without_panicking_across_the_real_corpus() {
    let mut walk = Walk { checked: 0, missing_required: Vec::new() };

    for path in corpus_files() {
        walk_file(&path, &mut walk);
    }

    // A FLOOR, NOT A FIXED COUNT — the corpus grows, and this only needs to
    // catch the walker itself silently breaking (a context-transition it
    // stops recognizing, the way `Hecks.bluebook` -> `Bluebook` once did —
    // found by exactly this regression, mid-build : 143 lines checked
    // before that fix, 3100 after). 1000 is comfortably below today's count
    // with room to grow, not a ceiling.
    assert!(
        walk.checked > 1000,
        "only {} covered keyword lines matched across the real corpus — suspiciously low, the walker likely lost a context transition",
        walk.checked
    );
    assert!(
        walk.missing_required.is_empty(),
        "{} required argument(s) produced no binding against real corpus text:\n{}",
        walk.missing_required.len(),
        walk.missing_required.join("\n"),
    );
}
