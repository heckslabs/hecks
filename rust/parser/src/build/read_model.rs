//! Mirrors a read model's `include` head gathering — pluralization,
//! dedup, and the `many:`/`as:` shape each `aggregate_heads` row carries
//! (`ReadModelBuilder#add_aggregate_head`).
//!
//! STAGE 3: `aggregate_heads` below, called from `parse::read_model`,
//! confirmed real by console_settings.bluebook's `Styles`/`Curated`
//! reports — both ROOTLESS (no `reference_to`, `parse::read_model`
//! refuses that word as not-yet-implemented), so `reference_target` is
//! always `None` here for now and every `include`d head is `many: true`
//! (`target != reference_target` is vacuously true against `None`).
//! `group_by`'s own field list needs no derivation beyond "the bare
//! symbol names given" — handled directly in `parse::read_model` instead
//! of a function here, the same "trivial enough not to need its own
//! module function" call `build/query_derive.rs`'s own header already
//! makes for `sets`' four named forms living beside `where`'s.

use crate::build::naming;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// `ReadModelBuilder#add_aggregate_head` — one call per `include Type[,
/// as: name]` line, in the order they were written (order-independent in
/// Ruby too: "The includes are collected raw and resolved at build, when
/// the reference is known"). `output` defaults to `Naming.plural(Naming
/// .snake(target))` when `many` (every include here, since
/// `reference_target` is always `None` for now) and no `as:` was given.
/// Refuses two includes minting the same `as:` name, the same guard
/// `add_aggregate_head` itself raises (`"#{@name} already projects
/// #{output}"`).
pub fn aggregate_heads(
    file: &str,
    line: usize,
    read_model_name: &str,
    includes: &[(String, Option<String>)],
    reference_target: Option<&str>,
) -> ParseResult<Vec<ir::AggregateHead>> {
    let mut heads: Vec<ir::AggregateHead> = Vec::new();

    for (target, as_name) in includes {
        let many = Some(target.as_str()) != reference_target;
        let output = as_name
            .clone()
            .unwrap_or_else(|| if many { naming::plural(&naming::snake(target)) } else { naming::snake(target) });

        if heads.iter().any(|head| head.as_name == output) {
            return Err(Diagnostic::new(file, line, format!("{read_model_name} already projects {output}")));
        }

        heads.push(ir::AggregateHead { aggregate: target.clone(), as_name: output, many });
    }

    Ok(heads)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pluralizes_a_many_side_head_with_no_as() {
        let heads = aggregate_heads("f.bluebook", 1, "Styles", &[("StateStyle".to_string(), None)], None).unwrap();
        assert_eq!(heads.len(), 1);
        assert_eq!(heads[0].aggregate, "StateStyle");
        assert_eq!(heads[0].as_name, "state_styles");
        assert!(heads[0].many);
    }

    #[test]
    fn keeps_an_explicit_as_name_verbatim() {
        let heads = aggregate_heads("f.bluebook", 1, "WidgetSummary", &[("Widget".to_string(), Some("widget".to_string()))], None).unwrap();
        assert_eq!(heads[0].as_name, "widget");
    }

    #[test]
    fn refuses_two_includes_projecting_the_same_name() {
        let err = aggregate_heads(
            "f.bluebook",
            1,
            "Dup",
            &[("Widget".to_string(), Some("thing".to_string())), ("Gadget".to_string(), Some("thing".to_string()))],
            None,
        )
        .unwrap_err();
        assert!(err.message.contains("already projects thing"));
    }
}
