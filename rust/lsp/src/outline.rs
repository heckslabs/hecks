//! A text-only outline of a `.bluebook`/`.hecksagon` buffer — every
//! named top-level construct (`aggregate "Order" do` ... `end`), nested
//! by `do`/`end` depth, with the line range each spans. Backs both
//! `textDocument/documentSymbol` and `textDocument/definition`
//! (`main.rs` resolves a bare identifier by searching outlines for a
//! symbol of that name).
//!
//! DELIBERATELY NOT SOURCED FROM `hecks-parse`'s OWN IR, unlike
//! `diagnostics.rs`: `rust/parser/src/ir.rs` carries no source line for
//! any construct (confirmed — there is no `line` field anywhere in it),
//! so there is nothing to navigate to even when a parse fully succeeds.
//! And a parse often DOESN'T fully succeed yet — Stage 1 stubs return
//! `not_yet_implemented` for whole construct kinds
//! (`rust/parser/src/main.rs::COVERED_PAIRS`'s own header), which would
//! leave `documentSymbol` empty for most of the real corpus if it only
//! ever ran after a clean parse. This scans the buffer directly instead
//! — line-based, no dependency on `hecks-parse` succeeding at all — at
//! the cost of being a second, unverified idea of the grammar rather
//! than a projection of `syntax.bluebook` the way `rust/parser`'s own
//! `keywords.rs` is (see that file's header, and `rust/lsp/README.md`'s
//! own note on this trade-off). The eight keywords below are read
//! straight off `syntax.bluebook`'s own `Bluebook`/`Aggregate` argument
//! lists, not guessed, and kept to exactly the constructs worth jumping
//! to — this is an outline, not a parser.
//!
//! THE GRAMMAR'S OWN REGULARITY IS WHAT MAKES THIS SAFE: `rust/parser`'s
//! own lexer refuses any line that isn't one of a small fixed set of
//! shapes (`lex.rs::classify` — no bare Ruby expressions, no `if`, no
//! local assignment ever admitted), so a real, well-formed `.bluebook`
//! file only ever opens a block with a line ending in `do` and closes it
//! with a line that is bare `end` — no one-line `do ... end`, no
//! `do |args|` block parameters anywhere in the real corpus (confirmed:
//! `grep -n 'do |' examples/**/*.bluebook` finds none). A do/end depth
//! counter is a much shakier idea in general Ruby; it's a reasonably
//! safe one here.
//!
//! A BUFFER MID-EDIT CAN HAVE UNBALANCED `do`/`end` — the one real
//! failure mode: a stack that never pops (later symbols nest under a
//! long-since-should-have-closed one) or pops early. Self-corrects the
//! next time depth balances out; never panics either way.

pub struct Symbol {
    pub name: String,
    pub kind: Kind,
    pub start_line: usize, // 1-indexed, the declaring line itself
    pub end_line: usize,   // 1-indexed, the line holding this block's own closing `end`
    pub children: Vec<Symbol>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Aggregate,
    Entity,
    ValueObject,
    Command,
    Query,
    Policy,
    ProcessManager,
    ReadModel,
}

const CONSTRUCTS: &[(&str, Kind)] = &[
    ("aggregate", Kind::Aggregate),
    ("entity", Kind::Entity),
    ("value_object", Kind::ValueObject),
    ("command", Kind::Command),
    ("query", Kind::Query),
    ("policy", Kind::Policy),
    ("process_manager", Kind::ProcessManager),
    ("read_model", Kind::ReadModel),
];

/// Kinds a `reference_to`/`belongs_to` bare identifier can legally name
/// — the only symbols `main.rs`'s `find_definition` resolves against.
/// `command`/`query`/`policy`/`process_manager`/`read_model` names are
/// never referenced by a bare constant elsewhere in the corpus the way
/// a type name is, so they're left out of definition lookup (they still
/// appear in `documentSymbol`'s full outline).
pub fn is_reference_target(kind: Kind) -> bool {
    matches!(kind, Kind::Aggregate | Kind::Entity | Kind::ValueObject)
}

struct Frame {
    name: String,
    kind: Kind,
    start_line: usize,
    depth_at_push: usize,
    children: Vec<Symbol>,
}

pub fn outline(text: &str) -> Vec<Symbol> {
    let mut stack: Vec<Frame> = Vec::new();
    let mut roots: Vec<Symbol> = Vec::new();
    let mut depth: usize = 0;

    for (idx, raw_line) in text.lines().enumerate() {
        let line_no = idx + 1;
        let trimmed = raw_line.trim();

        if let Some((name, kind)) = opens_construct(trimmed) {
            stack.push(Frame { name, kind, start_line: line_no, depth_at_push: depth, children: Vec::new() });
            depth += 1;
            continue;
        }

        if trimmed == "do" || trimmed.ends_with(" do") {
            depth += 1;
            continue;
        }

        if trimmed == "end" {
            depth = depth.saturating_sub(1);
            if matches!(stack.last(), Some(frame) if frame.depth_at_push == depth) {
                let frame = stack.pop().expect("just matched Some(frame) above");
                let symbol = Symbol {
                    name: frame.name,
                    kind: frame.kind,
                    start_line: frame.start_line,
                    end_line: line_no,
                    children: frame.children,
                };
                match stack.last_mut() {
                    Some(parent) => parent.children.push(symbol),
                    None => roots.push(symbol),
                }
            }
        }
    }

    roots
}

fn opens_construct(trimmed: &str) -> Option<(String, Kind)> {
    for (keyword, kind) in CONSTRUCTS {
        let Some(after) = trimmed.strip_prefix(keyword).and_then(|r| r.strip_prefix(" \"")) else {
            continue;
        };
        let Some(end_quote) = after.find('"') else { continue };
        if after[end_quote + 1..].trim() == "do" {
            return Some((after[..end_quote].to_string(), *kind));
        }
    }
    None
}

/// Depth-first search for a symbol named exactly `name` among `symbols`
/// and their descendants — `reference_to`/`belongs_to` targets are
/// looked up by bare name regardless of nesting depth (the language
/// names one idea one way, ADR 0025: a type name is unique across the
/// chapter it's declared in, not just within its immediate parent).
pub fn find_by_name<'a>(symbols: &'a [Symbol], name: &str) -> Option<&'a Symbol> {
    for symbol in symbols {
        if symbol.name == name && is_reference_target(symbol.kind) {
            return Some(symbol);
        }
        if let Some(found) = find_by_name(&symbol.children, name) {
            return Some(found);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const PIZZAS: &str = r#"Hecks.bluebook "Pizzas" do
  aggregate "Order" do
    value_object "PizzaName" do
      attribute :value, String
    end

    command "CreatePizza" do
      given "must be positive" do
        amount > 0
      end
    end

    query "Available" do
    end
  end

  policy "OnPizzaPaymentReceived" do
    on "PizzaPaymentReceived"
    trigger Order::Purchase
  end
end
"#;

    #[test]
    fn nests_constructs_by_do_end_depth() {
        let roots = outline(PIZZAS);
        assert_eq!(roots.len(), 2); // Order, OnPizzaPaymentReceived
        let order = &roots[0];
        assert_eq!(order.name, "Order");
        assert!(matches!(order.kind, Kind::Aggregate));
        assert_eq!(order.children.len(), 3); // PizzaName, CreatePizza, Available
        assert_eq!(order.children[1].name, "CreatePizza");
        assert!(matches!(order.children[1].kind, Kind::Command));
    }

    #[test]
    fn a_nested_do_end_block_does_not_split_its_parent() {
        let roots = outline(PIZZAS);
        let create_pizza = &roots[0].children[1];
        // The `given ... do ... end` block inside CreatePizza must not
        // close CreatePizza's own block early.
        assert_eq!(create_pizza.end_line, 11);
    }

    #[test]
    fn finds_a_value_object_by_bare_name_anywhere_in_the_tree() {
        let roots = outline(PIZZAS);
        let found = find_by_name(&roots, "PizzaName").expect("finds it");
        assert!(matches!(found.kind, Kind::ValueObject));
    }

    #[test]
    fn a_command_is_not_a_reference_target() {
        let roots = outline(PIZZAS);
        assert!(find_by_name(&roots, "CreatePizza").is_none());
    }
}
