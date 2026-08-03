//! THE ARGUMENT BINDER — the rung `bin/ir_dispatch_words`'s own header named
//! and left undone: "so does every word's ARGUMENT shape... a materially
//! harder problem solved separately, if it is solved at all." That script
//! generates WHICH WORD opens WHICH CATEGORY ; `bin/ir_syntax_bindings`
//! (previous milestone) generates WHAT EACH WORD'S OWN ARGUMENTS MEAN, as
//! `ir_syntax_bindings::KEYWORD_BINDINGS`. This module is what turns a real
//! line of `.bluebook` text plus one of those declared bindings into actual
//! field values. It reuses the two primitives that are already genuinely
//! GENERIC (`parse_blocks::split_top_level_commas` — quote/depth-aware comma
//! splitting, and `is_kwarg` — the same `name: value` detection
//! `parse_attribute` already uses) rather than re-deriving either ; the
//! per-call-site extractors (`extract_word_after`, `parse_flag_kwarg`, ...)
//! were built for "search a literal substring anywhere in the line" ad hoc
//! reads and do not compose into "the Nth positional, or this named
//! argument, of an already-identified keyword" the way a table-driven binder
//! needs, so this module's own `split_line`/`bind_scalar` are the smaller
//! generic replacement for that shape of work, not a duplicate of the old
//! one.
//!
//! NOT YET WIRED IN. This is the binder alone, proven against hand-picked
//! lines. Cutting a real `parse_X` function over to call it — deleting the
//! hand-written extraction it replaces — is the next milestone, verified
//! first by a corpus-wide differential check (parity between the old
//! hand-written reading and this one) before anything is deleted.

use crate::bluebook::ir_syntax_bindings::KeywordBinding;
use crate::bluebook::parse_blocks::{is_kwarg, split_top_level_commas};
use crate::parser_helpers::extract_string;
use std::collections::HashMap;

/// ONE ARGUMENT'S BOUND VALUE, kind-tagged the way `Syntax::ArgumentKind`
/// already is — `Text`/`Symbol`/`Number`/`Literal`/`Constant` all read as a
/// Rust `String` in the end (matching every existing IR struct field, which
/// is String or Option<String> for anything that is not itself a list or a
/// nested compound — see bin/ir_structs' own `project_field`), so they share
/// one variant ; `Flag` and `List` need their own shape to survive.
#[derive(Debug, Clone, PartialEq)]
pub enum BoundValue {
    Text(String),
    Flag(bool),
    List(Vec<String>),
}

impl BoundValue {
    pub fn into_text(self) -> Option<String> {
        match self {
            BoundValue::Text(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_text(&self) -> Option<&str> {
        match self {
            BoundValue::Text(text) => Some(text.as_str()),
            _ => None,
        }
    }
}

/// A `pairs`-kind argument's own pair, read verbatim — key text, value text,
/// neither interpreted. What a caller does with one depends on the owning
/// `ArgumentBinding.pairs_shape` (see that field's own doc in
/// syntax.bluebook), which this module does not decide — it only reads.
#[derive(Debug, Clone, PartialEq)]
pub struct Pair {
    pub key: String,
    pub value: String,
}

/// EVERY ORDINARY (non-`pairs`) BINDING PRODUCED FROM ONE LINE, plus every
/// `pairs`-kind argument's own raw pairs, kept separate — a pairs argument's
/// pairs are never a single `BoundValue`, so folding them into the same map
/// would either lose the multiplicity (`elements`/`verbatim`) or need a
/// `Vec<BoundValue>` variant nothing else uses.
#[derive(Debug, Clone, Default)]
pub struct Bindings {
    /// Keyed by the ArgumentBinding's OWN `fills` — the field this value
    /// lands on, on whatever compound `append_to` (see `KeywordBinding`)
    /// says it lands on.
    pub fields: HashMap<String, BoundValue>,
    /// Keyed by the ArgumentBinding's `named` (or "" for the positional
    /// pairs case, of which a keyword can only ever have one) — a pairs
    /// argument's own pairs, unbound, for the caller to interpret per
    /// `pairs_shape`.
    pub pairs: HashMap<String, Vec<Pair>>,
}

impl Bindings {
    /// A bound field's text, if it bound at all — the ordinary case for
    /// scalar String fields (`Command.role`, `Policy.on_event`, ...), which
    /// is most of them.
    pub fn text(&self, field: &str) -> Option<String> {
        self.fields.get(field).and_then(BoundValue::as_text).map(str::to_string)
    }

    /// A bound flag field, defaulting to `false` when absent — matching
    /// every declared `flag`-kind argument's own convention (`optional:`
    /// unset means not optional), the same default `parse_flag_kwarg`
    /// already returns.
    pub fn flag(&self, field: &str) -> bool {
        matches!(self.fields.get(field), Some(BoundValue::Flag(true)))
    }

    /// A bound list field, if it bound at all.
    pub fn list(&self, field: &str) -> Option<&[String]> {
        match self.fields.get(field) {
            Some(BoundValue::List(items)) => Some(items.as_slice()),
            _ => None,
        }
    }
}

/// THE (keyword, context) LOOKUP a real `parse_X` cutover needs before it
/// can call `bind_keyword` at all — the caller already knows its own
/// context (it is the function whose body this line was found in), so this
/// only has to find WHICH keyword the line starts with, the same
/// `keyword_matches` word-boundary check `dispatch_block`/`parse_aggregate`
/// already use for category-opening words, extended here to every word
/// `ir_syntax_bindings` covers, category-opening or not.
pub fn find_binding(context: &str, line: &str) -> Option<&'static KeywordBinding> {
    crate::bluebook::ir_syntax_bindings::KEYWORD_BINDINGS
        .iter()
        .find(|binding| binding.context == context && crate::bluebook::parser::keyword_matches(line, binding.keyword))
}

/// SPLITS A LINE INTO ITS OWN TOP-LEVEL ARGUMENTS, positional and named —
/// the one part of this module that is not a thin wrapper, because nothing
/// existing did this GENERICALLY (every hand-written `parse_X` walks its own
/// line by hand, differently). Reuses `split_top_level_commas` (already
/// depth/quote-aware) and `is_kwarg` (already the exact "is this part
/// `name: value`" check `parse_attribute`'s own kwarg detection uses) rather
/// than re-deriving either.
struct SplitLine<'a> {
    positional: Vec<&'a str>,
    named: HashMap<&'a str, &'a str>,
}

fn split_line<'a>(remainder: &'a str) -> SplitLine<'a> {
    let mut positional = Vec::new();
    let mut named = HashMap::new();
    for part in split_top_level_commas(remainder) {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if is_kwarg(part) {
            let colon = part.find(':').expect("is_kwarg guarantees a colon");
            named.insert(part[..colon].trim(), part[colon + 1..].trim());
        } else {
            positional.push(part);
        }
    }
    SplitLine { positional, named }
}

/// THE TEXT AFTER THE KEYWORD ITSELF, with any wrapping parens and a
/// trailing block-opener (`do`/`{`) stripped — `where(a: 1)` and `where a: 1`
/// read identically, matching every existing hand-written reader's own
/// tolerance for the parenthesized form.
fn arguments_text<'a>(line: &'a str, keyword: &str) -> &'a str {
    let after = line.find(keyword).map(|i| &line[i + keyword.len()..]).unwrap_or(line);
    let after = after.trim();
    let after = after.strip_prefix('(').unwrap_or(after);
    let after = after.strip_suffix("do").map(str::trim).unwrap_or(after);
    after.strip_suffix(')').unwrap_or(after).trim()
}

/// A `pairs` BLOB'S OWN CONTENT — strips one layer of `{...}` if present
/// (the `named:` forms — `append: { ... }`, `with: { ... }`, `transition: {
/// ... }` — are always written braced in the corpus) and returns the rest
/// unwrapped otherwise (the positional `elements` form — `where a: 1, b: 2`
/// — is never braced).
fn pairs_blob(text: &str) -> &str {
    let text = text.trim();
    match (text.strip_prefix('{'), text.ends_with('}')) {
        (Some(inner), true) => inner[..inner.len() - 1].trim(),
        _ => text,
    }
}

/// CLEANS ONE `fields`-shaped PAIR'S OWN KEY OR VALUE into a plain scalar
/// token — trailing comma, leading colon, and surrounding quotes stripped.
/// Matches `parse_pm_handler`'s own former `state_token` byte for byte : a
/// `fields`-shaped pair (`on`'s `transition:`, `Lifecycle`'s own
/// `transition`) always becomes a plain state/command name, unlike
/// `elements`/`verbatim` pairs, which must keep their raw text (`where`'s
/// own nested comparator-hash detection, `with:`'s deliberately
/// uninterpreted capture) — so this is NOT applied inside `split_pairs`
/// itself, only by callers that know their `pairs_shape` is `fields`.
pub fn state_token(raw: &str) -> String {
    raw.trim()
        .trim_end_matches(',')
        .trim()
        .trim_start_matches(':')
        .trim_matches('"')
        .trim()
        .to_string()
}

/// ONE `pairs` BLOB, SPLIT INTO ITS OWN PAIRS — `key: value` (a real Ruby
/// hash pair) or `key => value` (the hash-rocket form `transition`'s own
/// positional pair uses). Neither side is interpreted ; a caller reads
/// `value` per whatever `pairs_shape` says to do with it.
fn split_pairs(blob: &str) -> Vec<Pair> {
    split_top_level_commas(blob)
        .into_iter()
        .filter_map(|part| {
            let part = part.trim();
            if part.is_empty() {
                return None;
            }
            if let Some(colon) = part.find(':').filter(|_| is_kwarg(part)) {
                return Some(Pair {
                    key: part[..colon].trim().to_string(),
                    value: part[colon + 1..].trim().to_string(),
                });
            }
            let arrow = part.find("=>")?;
            Some(Pair {
                key: part[..arrow].trim().trim_matches('"').to_string(),
                value: part[arrow + 2..].trim().to_string(),
            })
        })
        .collect()
}

/// A TOKEN, READ PER `kind` — the kind-dispatch this whole module exists to
/// make table-driven. `pairs` is handled by the caller (`bind_keyword`), not
/// here : a pairs argument's "token" is a whole sub-blob, not a scalar.
fn bind_scalar(kind: &str, token: &str) -> Option<BoundValue> {
    match kind {
        "flag" => Some(BoundValue::Flag(token.trim().starts_with("true"))),
        "text" => extract_string(token).map(BoundValue::Text),
        // REQUIRES THE LEADING COLON — the one thing that actually spells a
        // Ruby symbol, and what tells `on`'s two declared event_type rows
        // (`text` for `"SightingRaised"`, `symbol` for the `:refused`
        // sentinel — a real corpus finding, M4) apart. Without this guard a
        // quoted string ALSO matches (`trim_start_matches(':')` is a no-op
        // on a token with no leading colon) and clobbers whichever row ran
        // first, the same failure mode `list`'s own bracket requirement
        // guards against below.
        // A BARE symbol (`:name`) OR A QUOTED ONE (`:"a.dotted.path"`) —
        // Ruby's own symbol literal syntax admits both, and a dotted field
        // name (`correlates_by :"end_to_end.value"`) is not a valid BARE
        // symbol at all (`:end_to_end.value` is not one token to Ruby),
        // so it is always written quoted. The quoted form's own quotes are
        // stripped here, not left for the caller to notice they are still
        // there.
        "symbol" => {
            let rest = token.trim().strip_prefix(':')?;
            let text = match rest.strip_prefix('"') {
                Some(quoted) => quoted.split('"').next().unwrap_or(quoted).to_string(),
                None => rest.to_string(),
            };
            Some(BoundValue::Text(text))
        }
        "constant" | "number" | "literal" => {
            Some(BoundValue::Text(token.trim().trim_start_matches(':').to_string()))
        }
        // STRICTLY BRACKETED — `transition`'s own `from:` is declared TWICE,
        // once `text` and once `list` (`transition "X" => "Y", from: "new"`
        // vs `from: ["a", "b"]`), because one named argument genuinely
        // admits either shape. Returning `None` for a bare, non-bracketed
        // token here (rather than treating a lone token as a one-element
        // list) is what lets the `text` row's own binding survive — both
        // rows are tried for the same slot, and only the one whose kind
        // actually matches the token's own syntax should win.
        "list" => {
            let trimmed = token.trim();
            let inner = trimmed.strip_prefix('[')?.strip_suffix(']')?;
            let items = split_top_level_commas(inner)
                .into_iter()
                .map(|item| item.trim().trim_matches('"').trim_start_matches(':').to_string())
                .filter(|item| !item.is_empty())
                .collect();
            Some(BoundValue::List(items))
        }
        other => panic!("bind_scalar called with kind {other:?}, which is not a scalar ArgumentKind"),
    }
}

/// THE DRIVER. Given a keyword's own declared bindings and a real line
/// (already known to start with that keyword — the caller's own
/// `keyword_matches`/`ir_dispatch_words` lookup already established that),
/// reads every declared argument off the line : scalar kinds land in
/// `Bindings.fields`, keyed by their OWN `fills` ; `pairs`-kind arguments
/// land in `Bindings.pairs`, keyed by `named` ("" for the positional form),
/// unbound — `pairs_shape` says what to do with them, and that decision
/// belongs to the caller applying the bindings, not to this reader.
///
/// `selects` is applied here, not deferred : a `selects: "op=increment"` row
/// that matched (its own named/positional slot was present on the line)
/// pushes `op` -> `"increment"` into `fields` alongside whatever `fills`
/// itself names, the same one pass.
pub fn bind_keyword(binding: &KeywordBinding, line: &str) -> Bindings {
    let text = arguments_text(line, binding.keyword);

    // THE ONE SPECIAL CASE: a lone POSITIONAL pairs argument (`where`'s own
    // shape) consumes the ENTIRE remainder as its own blob directly — Ruby's
    // `where(a: 1, b: 2)` passes ONE hash built from every top-level pair,
    // not two arguments of `where` itself, so splitting `text` into
    // positional/named parts FIRST (the ordinary path below) would read
    // `a: 1` as a NAMED ARGUMENT CALLED `a`, which `where` does not declare.
    if let [only] = binding.arguments {
        if only.kind == "pairs" && only.named.is_empty() {
            let mut bindings = Bindings::default();
            bindings.pairs.insert(String::new(), split_pairs(pairs_blob(text)));
            return bindings;
        }
    }

    let split = split_line(text);
    let mut positional_index = 0usize;
    let mut bindings = Bindings::default();

    for arg in binding.arguments {
        let token: Option<&str> = if !arg.at.is_empty() {
            let want: usize = arg.at.parse().expect("Syntax::Argument.at is a small positive integer");
            let found = split.positional.get(want.saturating_sub(1)).copied();
            if found.is_some() {
                positional_index = positional_index.max(want);
            }
            found
        } else if !arg.named.is_empty() {
            split.named.get(arg.named).copied()
        } else {
            None
        };
        let _ = positional_index;

        let Some(token) = token else { continue };

        if arg.kind == "pairs" {
            bindings.pairs.insert(arg.named.to_string(), split_pairs(pairs_blob(token)));
            continue;
        }

        let Some(value) = bind_scalar(arg.kind, token) else { continue };

        if !arg.selects.is_empty() {
            if let Some((field, selected)) = arg.selects.split_once('=') {
                bindings.fields.insert(field.to_string(), BoundValue::Text(selected.to_string()));
            }
        }

        if !arg.fills.is_empty() {
            bindings.fields.insert(arg.fills.to_string(), value);
        }
    }

    bindings
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bluebook::ir_syntax_bindings::KEYWORD_BINDINGS;

    fn binding_for<'a>(keyword: &str, context: &str) -> &'a KeywordBinding {
        KEYWORD_BINDINGS
            .iter()
            .find(|b| b.keyword == keyword && b.context == context)
            .unwrap_or_else(|| panic!("no generated binding for {keyword}/{context}"))
    }

    #[test]
    fn text_kind_reads_a_quoted_string() {
        let binding = binding_for("role", "Command");
        let bindings = bind_keyword(binding, "role \"Teller\"");
        assert_eq!(bindings.fields.get("role"), Some(&BoundValue::Text("Teller".to_string())));
    }

    #[test]
    fn flag_kind_reads_true_and_defaults_absent_to_false() {
        let binding = binding_for("attribute", "Command");
        let present = bind_keyword(binding, "attribute :amount, Money, optional: true");
        assert_eq!(present.fields.get("optional"), Some(&BoundValue::Flag(true)));

        let absent = bind_keyword(binding, "attribute :amount, Money");
        assert_eq!(absent.fields.get("optional"), None);
    }

    #[test]
    fn symbol_kind_strips_the_leading_colon() {
        let binding = binding_for("attribute", "Command");
        let bindings = bind_keyword(binding, "attribute :amount, Money");
        assert_eq!(bindings.fields.get("name"), Some(&BoundValue::Text("amount".to_string())));
    }

    #[test]
    fn constant_kind_reads_a_bare_type_name() {
        let binding = binding_for("attribute", "Command");
        let bindings = bind_keyword(binding, "attribute :amount, Money");
        assert_eq!(bindings.fields.get("type"), Some(&BoundValue::Text("Money".to_string())));
    }

    #[test]
    fn number_kind_reads_a_bare_numeric_token() {
        let binding = binding_for("limit", "Query");
        let bindings = bind_keyword(binding, "limit 10");
        assert_eq!(bindings.fields.get("limit"), Some(&BoundValue::Text("10".to_string())));
    }

    #[test]
    fn selects_pushes_op_alongside_source() {
        let binding = binding_for("sets", "Command");
        let bindings = bind_keyword(binding, "sets :balance, increment: :amount");
        assert_eq!(bindings.fields.get("op"), Some(&BoundValue::Text("increment".to_string())));
        assert_eq!(bindings.fields.get("source"), Some(&BoundValue::Text("amount".to_string())));
        assert_eq!(bindings.fields.get("target"), Some(&BoundValue::Text("balance".to_string())));
    }

    #[test]
    fn fields_shaped_pairs_read_as_a_single_pair_by_key() {
        // Lifecycle's own `transition` — a hash-rocket positional pair
        // (command => to_state) plus a named `from:`.
        let binding = binding_for("transition", "Lifecycle");
        let bindings = bind_keyword(binding, r#"transition "Open" => "active", from: "new""#);
        let pairs = bindings.pairs.get("").expect("the positional pairs argument binds under \"\"");
        assert_eq!(pairs, &vec![Pair { key: "Open".to_string(), value: "\"active\"".to_string() }]);
        assert_eq!(bindings.fields.get("from_state"), Some(&BoundValue::Text("new".to_string())));
    }

    #[test]
    fn fields_shaped_pairs_read_a_braced_named_argument() {
        let binding = binding_for("on", "ProcessManager");
        let bindings = bind_keyword(binding, r#"on "SightingRaised", transition: { "watching" => "watching" }"#);
        assert_eq!(bindings.fields.get("event_type"), Some(&BoundValue::Text("SightingRaised".to_string())));
        let pairs = bindings.pairs.get("transition").unwrap();
        assert_eq!(pairs, &vec![Pair { key: "watching".to_string(), value: "\"watching\"".to_string() }]);
    }

    #[test]
    fn elements_shaped_pairs_read_every_top_level_pair() {
        let binding = binding_for("where", "Query");
        let bindings = bind_keyword(binding, r#"where(balance: {gte: 100}, status: "open")"#);
        let pairs = bindings.pairs.get("").unwrap();
        assert_eq!(pairs.len(), 2);
        assert_eq!(pairs[0], Pair { key: "balance".to_string(), value: "{gte: 100}".to_string() });
        assert_eq!(pairs[1], Pair { key: "status".to_string(), value: "\"open\"".to_string() });
    }

    #[test]
    fn verbatim_shaped_pairs_read_every_key_token_pair_uninterpreted() {
        let binding = binding_for("dispatch", "Handler");
        let bindings = bind_keyword(binding, r#"dispatch "Banking::Account.Debit", with: { number: :source, amount: :amount }"#);
        assert_eq!(bindings.fields.get("command_name"), Some(&BoundValue::Text("Banking::Account.Debit".to_string())));
        let pairs = bindings.pairs.get("with").unwrap();
        assert_eq!(pairs, &vec![
            Pair { key: "number".to_string(), value: ":source".to_string() },
            Pair { key: "amount".to_string(), value: ":amount".to_string() },
        ]);
    }
}
