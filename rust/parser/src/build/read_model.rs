//! Read model `include` head gathering: pluralization, dedup, and the `many:`/`as:`
//! shape of each aggregate head.

use crate::build::naming;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// Builds the `aggregate_heads` for a read model's `include Type[, as: name]` lines.
///
/// A head is `many` unless it names `reference_target`; `output` defaults to the
/// plural (many) or singular snake name. Refuses two includes projecting the same name.
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
        let output = as_name.clone().unwrap_or_else(|| {
            if many {
                naming::plural(&naming::snake(target))
            } else {
                naming::snake(target)
            }
        });

        if heads.iter().any(|head| head.as_name == output) {
            return Err(Diagnostic::new(
                file,
                line,
                format!("{read_model_name} already projects {output}"),
            ));
        }

        heads.push(ir::AggregateHead {
            aggregate: target.clone(),
            as_name: output,
            many,
        });
    }

    Ok(heads)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_an_explicit_as_name_verbatim() {
        let heads = aggregate_heads(
            "f.bluebook",
            1,
            "WidgetSummary",
            &[("Widget".to_string(), Some("widget".to_string()))],
            None,
        )
        .unwrap();
        assert_eq!(heads[0].as_name, "widget");
    }

    #[test]
    fn a_reference_target_naming_no_included_head_leaves_every_head_many() {
        let heads = aggregate_heads(
            "f.bluebook",
            1,
            "ComplianceDashboard",
            &[("CardPayment".to_string(), None)],
            Some("Account"),
        )
        .unwrap();
        assert!(heads[0].many, "no included head equals the reference target, so all stay many");
    }

    #[test]
    fn refuses_two_includes_projecting_the_same_name() {
        let err = aggregate_heads(
            "f.bluebook",
            1,
            "Dup",
            &[
                ("Widget".to_string(), Some("thing".to_string())),
                ("Gadget".to_string(), Some("thing".to_string())),
            ],
            None,
        )
        .unwrap_err();
        assert!(err.message.contains("already projects thing"));
    }
}
