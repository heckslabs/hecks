//! Completion for the sentence form: the sentences that are legal at a cursor, drawn from the
//! same phrase table the parser reads, so an editor can never offer what the parser would refuse.
//!
//! The block a line stands in is found from the indentation of the lines above it: the nearest
//! line indented less is its header, and the header's phrase says what block it opens.

use std::fmt::Write as _;

use super::pattern::{match_sentence, Pattern};
use super::token::tokenize;
use super::Grammar;

/// One sentence an author could write at the cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    /// The sentence as the author reads it, with each fill-in shown as `<name>`.
    pub label: String,
    /// The fixed words it starts with, ready to type.
    pub insert: String,
    /// The whole sentence as an editor snippet, with a tab stop for each fill-in.
    pub snippet: String,
}

/// What can be written at the cursor: the block it stands in and the sentences legal there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    /// The block the cursor stands in, or "" when nothing is legal there.
    pub context: String,
    /// The legal sentences that fit what has been typed so far.
    pub items: Vec<Item>,
}

/// Words after which the rest of the line is a condition, not a sentence of the block.
const CONDITION_MARKERS: [&str; 2] = [" holds when ", "only when "];

/// The sentences legal at `line` (1-based) and `col` (1-based character column) of `source`.
pub fn complete(source: &str, line: usize, col: usize) -> Completion {
    let Ok(grammar) = Grammar::load() else {
        return nothing();
    };
    let lines: Vec<&str> = source.lines().collect();
    let current = lines.get(line.saturating_sub(1)).copied().unwrap_or("");
    let before: String = current.chars().take(col.saturating_sub(1)).collect();
    let indent = before.len() - before.trim_start().len();
    let typed = before.trim_start().to_lowercase();

    let above = &lines[..line.saturating_sub(1).min(lines.len())];
    let Some(context) = context_of(&grammar, above, indent) else {
        return nothing();
    };
    let (context, typed) = condition_part(&context, &typed);

    let items = grammar
        .in_context(&context)
        .into_iter()
        .filter_map(|phrase| item(&phrase.pattern, &typed))
        .collect();
    Completion { context, items }
}

const fn nothing() -> Completion {
    Completion {
        context: String::new(),
        items: Vec::new(),
    }
}

/// Whether a line says anything: not blank and not a comment.
fn is_meaningful(text: &str) -> bool {
    !text.trim().is_empty() && !text.trim_start().starts_with('#')
}

/// The block a line indented `indent` stands in, given the lines above it.
fn context_of(grammar: &Grammar, above: &[&str], indent: usize) -> Option<String> {
    if indent == 0 {
        return Some(if above.iter().any(|text| is_meaningful(text)) {
            "Domain".to_string()
        } else {
            "File".to_string()
        });
    }
    let header = above
        .iter()
        .rev()
        .filter(|text| is_meaningful(text))
        .find(|text| text.len() - text.trim_start().len() < indent)?;
    let text = header.trim();
    let text = text.strip_suffix('.').unwrap_or(text);
    let tokens = tokenize(text).ok()?;
    let opened = grammar
        .phrases
        .iter()
        .filter(|phrase| !phrase.row.opens.is_empty())
        .find(|phrase| match_sentence(&phrase.pattern, &tokens, text, &mut 0).is_some())?
        .row
        .opens;
    Some(if opened == "Domain" { "Vision" } else { opened }.to_string())
}

/// After `holds when` or `Where`, what is typed is a condition and the block is `Condition`.
fn condition_part(context: &str, typed: &str) -> (String, String) {
    for marker in CONDITION_MARKERS {
        let found = if marker.starts_with(' ') {
            typed.find(marker).map(|at| at + marker.len())
        } else {
            typed.starts_with(marker).then_some(marker.len())
        };
        if let Some(after) = found {
            return ("Condition".to_string(), typed[after..].to_string());
        }
    }
    (context.to_string(), typed.to_string())
}

/// The completion for one pattern, if what has been typed still fits it.
fn item(pattern: &Pattern, typed: &str) -> Option<Item> {
    let insert = fixed_start(pattern);
    let label = pattern.render();
    let fits = typed.is_empty()
        || label.to_lowercase().starts_with(typed)
        || insert.to_lowercase().starts_with(typed)
        || (!insert.is_empty() && typed.starts_with(&insert.to_lowercase()));
    fits.then(|| Item {
        label,
        insert,
        snippet: snippet(pattern),
    })
}

/// The words a pattern starts with before its first fill-in, as an author would type them: a
/// leading `(a|an)` becomes its first word, capitalised.
fn fixed_start(pattern: &Pattern) -> String {
    let source = &pattern.source;
    let head = &source[..source.find('{').unwrap_or(source.len())];
    let mut out = String::new();
    let mut chars = head.chars();
    while let Some(c) = chars.next() {
        if c == '(' {
            let body: String = chars.by_ref().take_while(|&inner| inner != ')').collect();
            let first = body.split('|').next().unwrap_or_default();
            out.push_str(&if out.is_empty() { capitalise(first) } else { first.to_string() });
        } else {
            out.push(c);
        }
    }
    out
}

fn capitalise(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map_or_else(String::new, |first| {
        first.to_uppercase().collect::<String>() + chars.as_str()
    })
}

/// The pattern as an editor snippet: `Rule ${1:description} holds when ${2:condition}$0`.
fn snippet(pattern: &Pattern) -> String {
    let mut out = String::new();
    let mut stop = 0;
    let mut chars = pattern.source.chars();
    let mut at_start = true;
    while let Some(c) = chars.next() {
        match c {
            '{' => {
                let body: String = chars.by_ref().take_while(|&inner| inner != '}').collect();
                stop += 1;
                let name = body.split(':').next().unwrap_or_default();
                let _ = write!(out, "${{{stop}:{name}}}");
            }
            '(' => {
                let body: String = chars.by_ref().take_while(|&inner| inner != ')').collect();
                let first = body.split('|').next().unwrap_or_default();
                out.push_str(&if at_start { capitalise(first) } else { first.to_string() });
            }
            '$' | '\\' | '}' => {
                out.push('\\');
                out.push(c);
            }
            other => out.push(other),
        }
        at_start = false;
    }
    out.push_str("$0");
    out
}

#[cfg(test)]
// reason: a `${1:name}` in a snippet is the editor's syntax, not a format argument.
#[allow(clippy::literal_string_with_formatting_args)]
mod tests {
    use super::*;

    const SOURCE: &str = "\
Domain: Cms

Aggregate: Page
  A page is identified by its slug.
  Command: Draft
    Who: Editor
    ";

    fn labels(completion: &Completion) -> Vec<&str> {
        completion.items.iter().map(|item| item.label.as_str()).collect()
    }

    #[test]
    fn the_top_of_a_file_offers_only_the_domain_line() {
        let found = complete("", 1, 1);
        assert_eq!(found.context, "File");
        assert_eq!(labels(&found), ["Domain: <name>"]);
    }

    #[test]
    fn inside_a_command_it_offers_the_command_sentences() {
        let found = complete(SOURCE, 7, 5);
        assert_eq!(found.context, "Command");
        assert!(labels(&found).contains(&"Goal: <goal>"), "{:?}", labels(&found));
        assert!(labels(&found).contains(&"When <names> (is|are) given"));
        assert!(!labels(&found).iter().any(|label| label.starts_with("Aggregate")));
    }

    #[test]
    fn what_has_been_typed_narrows_the_offer() {
        let source = format!("{SOURCE}Gi");
        let found = complete(&source, 7, 7);
        assert_eq!(labels(&found), ["Given <description> holds when <condition>"]);
        assert_eq!(found.items[0].insert, "Given ");
    }

    #[test]
    fn after_holds_when_it_offers_conditions() {
        let source = "Domain: Cms\n\nAggregate: Page\n  Command: Draft\n    Given \"x\" holds when ";
        let found = complete(source, 5, 26);
        assert_eq!(found.context, "Condition");
        assert!(labels(&found).contains(&"the <field> is not empty"));
    }

    #[test]
    fn a_snippet_has_a_tab_stop_for_each_fill_in() {
        let found = complete("Domain: Cms\n\nAggregate: Page\n  ", 4, 3);
        let rule = complete(SOURCE, 7, 5)
            .items
            .into_iter()
            .find(|item| item.label.starts_with("Given"));
        assert!(found.items.iter().any(|item| item.snippet == "Command: ${1:name}$0"));
        assert_eq!(
            rule.map(|item| item.snippet),
            Some("Given ${1:description} holds when ${2:condition}$0".to_string())
        );
    }
}
