//! A line-based outline of a `.bluebook`/`.hecksagon` buffer, nested by `do`/`end` depth.
//! Scanned directly rather than from the IR, which carries no lines and may not parse yet.

/// One named construct with the 1-indexed line range it spans.
pub struct Symbol {
    pub name: String,
    pub kind: Kind,
    pub start_line: usize, // 1-indexed declaring line
    pub end_line: usize,   // 1-indexed line of the closing `end`
    pub children: Vec<Symbol>,
}

/// The construct keywords the outline recognizes.
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

/// Whether a bare identifier can name this kind; only these are definition targets.
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

/// Depth-first search for a reference target named `name`, at any nesting depth (ADR 0025).
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
        // The nested `given ... do ... end` must not close CreatePizza early.
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
