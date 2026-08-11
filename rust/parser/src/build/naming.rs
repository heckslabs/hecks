//! Mirrors `Hecksagain::Naming` (`lib/hecksagain/naming.rb`) — the small,
//! pure name-shape conversions several other derivations lean on:
//! `pascal` (an attribute name -> a synthesized value-object type name,
//! `closed_sets.rs`), `snake` (a value-object type name -> a minted
//! attribute name, `identity.rs`/`references.rs`), plus `qualifier`/
//! `unqualified` for a policy's `on_event` splitting. Deliberately its own
//! module rather than inlined per-caller, matching the Ruby source's own
//! shape: every derivation that needs a name transform reads it from one
//! place, not a second hand-rolled copy per call site.

/// `Hecksagain::Naming.demodulise` — `"Pizzas::Order" -> "Order"`. A bare
/// constant written in a bluebook never carries a namespace prefix in
/// practice (the DSL's own `const_missing` hands back a plain Symbol), so
/// this is mostly a no-op here, kept for parity with the Ruby call sites
/// that always route a type name through it before minting an attribute.
pub fn demodulise(type_name: &str) -> String {
    type_name.rsplit("::").next().unwrap_or(type_name).to_string()
}

/// `Hecksagain::Naming.snake` — `"PizzaName" -> "pizza_name"`. Mirrors
/// the two-pass regex exactly: first split a run of capitals followed by
/// a Capital+lowercase (`"HTTPServer"` -> `"HTTP_Server"`), then split a
/// lowercase/digit followed by a capital (`"PizzaName"` -> `"Pizza_Name"`),
/// then lowercase the whole thing.
pub fn snake(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut pass1 = String::new();
    for (i, &ch) in chars.iter().enumerate() {
        let is_upper_run_boundary = ch.is_ascii_uppercase()
            && i > 0
            && chars[i - 1].is_ascii_uppercase()
            && i + 1 < chars.len()
            && chars[i + 1].is_ascii_lowercase();
        if is_upper_run_boundary {
            pass1.push('_');
        }
        pass1.push(ch);
    }

    let pass1_chars: Vec<char> = pass1.chars().collect();
    let mut pass2 = String::new();
    for (i, &ch) in pass1_chars.iter().enumerate() {
        let is_lower_to_upper_boundary = ch.is_ascii_uppercase()
            && i > 0
            && (pass1_chars[i - 1].is_ascii_lowercase() || pass1_chars[i - 1].is_ascii_digit());
        if is_lower_to_upper_boundary {
            pass2.push('_');
        }
        pass2.push(ch);
    }

    pass2.to_lowercase()
}

/// `Hecksagain::Naming.pascal` — `"pizza_name" -> "PizzaName"`. Not
/// exercised by pizzas.bluebook (its one closed set, `Size`, is a
/// hand-written sibling `value_object`, not the inline `attribute :size,
/// one_of(...)` shorthand this backs) — kept for the same reason `snake`
/// above is: a small, pure, easily-verified transform other derivations
/// lean on.
pub fn pascal(text: &str) -> String {
    text.split('_')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

/// `Hecksagain::Naming.plural` — the name a COLLECTION of something
/// takes, e.g. a read model's own many-side `include` head
/// (`ReadModelBuilder#add_aggregate_head`, `build/read_model.rs`) when no
/// `as:` is given: `"state_style" -> "state_styles"`, `"collection" ->
/// "collections"`. Three suffix rules, tried in order — `snake(target)`
/// is already applied by the caller before this runs, matching Ruby's own
/// `plural(snake(target))` call shape.
pub fn plural(text: &str) -> String {
    if text.len() > 1 {
        let last = &text[text.len() - 1..];
        let before_last = text.chars().rev().nth(1);
        if last == "y" && !matches!(before_last, Some('a' | 'e' | 'i' | 'o' | 'u')) {
            return format!("{}ies", &text[..text.len() - 1]);
        }
    }
    for suffix in ["s", "x", "z", "ch", "sh"] {
        if text.ends_with(suffix) {
            return format!("{text}es");
        }
    }
    format!("{text}s")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pluralizes_a_read_model_head_name() {
        assert_eq!(plural("state_style"), "state_styles");
        assert_eq!(plural("collection"), "collections");
        assert_eq!(plural("company"), "companies");
        assert_eq!(plural("box"), "boxes");
    }

    #[test]
    fn snakes_a_pascal_type_name() {
        assert_eq!(snake("PizzaName"), "pizza_name");
        assert_eq!(snake("Order"), "order");
    }

    #[test]
    fn pascals_a_snake_attribute_name() {
        assert_eq!(pascal("pizza_name"), "PizzaName");
        assert_eq!(pascal("size"), "Size");
    }

    #[test]
    fn demodulises_a_namespaced_constant() {
        assert_eq!(demodulise("Pizzas::Order"), "Order");
        assert_eq!(demodulise("Order"), "Order");
    }
}
