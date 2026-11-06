//! The IR-read queries answer what the generated tables answer: the same rows, and the same
//! answers byte for byte. Each domain feature proves its own tables, so run with one at a time.

use super::{for_ir, IrQueries, Lookup};
use crate::generated::active::{ENTITY_QUERIES, QUERIES};
use crate::kernel::cli::run;
use crate::kernel::Json;

#[cfg(feature = "pizzas")]
const IR: &[&str] = &[
    include_str!("../../generated/pizzas/ir.json"),
    include_str!("../../generated/governance/ir.json"),
];
#[cfg(feature = "banking")]
const IR: &[&str] = &[
    include_str!("../../generated/banking/ir.json"),
    include_str!("../../generated/governance/ir.json"),
    include_str!("../../generated/identity/ir.json"),
    include_str!("../../generated/bulk/ir.json"),
];
#[cfg(feature = "tenant_ledger")]
const IR: &[&str] = &[
    include_str!("../../generated/tenant_ledger/ir.json"),
    include_str!("../../generated/governance/ir.json"),
];
#[cfg(not(any(feature = "pizzas", feature = "banking", feature = "tenant_ledger")))]
const IR: &[&str] = &[];

fn ir_text() -> String {
    format!("[{}]", IR.join(","))
}

fn ir() -> Json {
    Json::parse(&ir_text()).unwrap_or(Json::Null)
}

#[cfg(any(feature = "pizzas", feature = "banking", feature = "tenant_ledger"))]
mod against_generated {
    use super::*;

    #[test]
    fn the_rows_read_from_the_ir_are_the_rows_the_generator_wrote() {
        let rows = IrQueries::from_ir(&ir()).named_rows();
        let verbs =
            |rows: &[&crate::kernel::QueryDef]| rows.iter().map(|r| r.verb).collect::<Vec<_>>();
        let generated: Vec<&crate::kernel::QueryDef> = QUERIES.iter().collect();
        assert_eq!(verbs(&rows), verbs(&generated));
        for (read, written) in rows.iter().zip(QUERIES) {
            assert_eq!(
                format!("{read:#?}"),
                format!("{written:#?}"),
                "{}",
                written.verb
            );
        }
    }

    #[test]
    fn the_entity_rows_read_from_the_ir_are_the_rows_the_generator_wrote() {
        let queries = IrQueries::from_ir(&ir());
        assert_eq!(
            format!("{:#?}", queries.entity_rows()),
            format!("{ENTITY_QUERIES:#?}")
        );
    }

    // Every verb the generated table holds, asked with no arguments and with arguments that fit
    // none of them, so a gate or a missing-argument refusal is compared too.
    fn every_verb_steps() -> String {
        let verbs = QUERIES
            .iter()
            .map(|q| q.verb)
            .chain(ENTITY_QUERIES.iter().map(|q| q.verb));
        let steps: Vec<String> = verbs
            .flat_map(|verb| {
                [
                    format!(r#"{{"query":"{verb}"}}"#),
                    format!(r#"{{"query":"{verb}","args":{{"ceiling":{{"cents":-1}},"x":[1]}}}}"#),
                    format!(r#"{{"query":"{verb}","args":{{"ceiling":{{"cents":"a"}},"limit":"a","after":1}}}}"#),
                ]
            })
            .collect();
        steps.join(",")
    }

    #[test]
    fn every_declared_query_answers_the_same_with_and_without_the_ir() {
        let steps = every_verb_steps();
        let generated = run(&format!(r#"{{"steps":[{steps}]}}"#));
        let interpreted = run(&format!(r#"{{"steps":[{steps}],"ir":{}}}"#, ir_text()));
        assert_eq!(interpreted, generated);
    }

    #[test]
    fn a_verb_the_ir_does_not_declare_is_refused_as_the_generated_path_refuses_it() {
        let step = r#"{"query":"Nowhere::Nothing.At"}"#;
        let generated = run(&format!(r#"{{"steps":[{step}]}}"#));
        let interpreted = run(&format!(r#"{{"steps":[{step}],"ir":{}}}"#, ir_text()));
        assert_eq!(interpreted, generated);
    }

    const OFFERED: [&str; 12] = [
        r"{}",
        r#"{"ceiling":1000}"#,
        r#"{"ceiling":-5}"#,
        r#"{"ceiling":null}"#,
        r#"{"ceiling":"x"}"#,
        r#"{"ceiling":[1]}"#,
        r#"{"ceiling":{"cents":-5}}"#,
        r#"{"ceiling":{"cents":1.5}}"#,
        r#"{"ceiling":{"cents":99999999999999999999}}"#,
        r#"{"ceiling":{"cents":3,"extra":1,"more":2}}"#,
        r#"{"ceiling":{}}"#,
        r#"{"actor_id":5,"region":[1],"after":{"a":1},"limit":"x","status":1.5}"#,
    ];

    // The interpreted gate refuses, word for word, what the generated `check_query_args` refuses.
    #[test]
    fn the_gate_read_from_the_ir_refuses_what_the_generated_gate_refuses() {
        let queries = IrQueries::from_ir(&ir());
        for query in QUERIES {
            for offered in OFFERED {
                let args = Json::parse(offered).unwrap_or(Json::Null);
                let generated = format!(
                    "{:?}",
                    crate::generated::active::check_query_args(query.verb, &args)
                );
                if let Some(read) = queries.check_args(query.verb, &args) {
                    assert_eq!(
                        format!("{read:?}"),
                        generated,
                        "{} offered {offered}",
                        query.verb
                    );
                }
            }
        }
    }

    #[test]
    fn the_rows_are_built_once_per_distinct_ir() {
        assert!(std::ptr::eq(for_ir(&ir()), for_ir(&ir())));
    }
}

#[cfg(feature = "pizzas")]
mod pizzas {
    use super::*;

    const STEPS: &str = r#"
        {"verb":"Pizzas::Order.CreatePizza","with":{"name":"Margherita","pizza":{"price_cents":1200,"size":"large"}}},
        {"verb":"Pizzas::Order.CreatePizza","with":{"name":"Marinara","pizza":{"price_cents":800,"size":"small"}}},
        {"verb":"Pizzas::Order.AddTopping","to":"Margherita","with":{"topping":"basil","amount":2}},
        {"verb":"Pizzas::Order.Purchase","to":"Margherita","with":{"amount":1500,"customer_name":"Ann"}}"#;

    const ASKS: [&str; 10] = [
        r#"{"query":"Pizzas::Order.Everything"}"#,
        r#"{"query":"Pizzas::Order.Available"}"#,
        r#"{"query":"Pizzas::Order.ByPrice"}"#,
        r#"{"query":"Pizzas::Order.ByPriceDescending"}"#,
        r#"{"query":"Pizzas::Order.ByCustomerUnsetLast"}"#,
        r#"{"query":"Pizzas::Order.Expensive"}"#,
        r#"{"query":"Pizzas::Order.CostingLessThan","args":{"ceiling":1000}}"#,
        r#"{"query":"Pizzas::Order.CostingLessThan","args":{"ceiling":{"cents":-5}}}"#,
        r#"{"query":"Pizzas::Order.CostingLessThan","args":{"ceiling":{"cents":"a"}}}"#,
        r#"{"query":"Pizzas::Order.CostingLessThan","args":{"ceiling":{"cents":5,"extra":1}}}"#,
    ];

    fn answer(with_ir: bool) -> String {
        let asks = ASKS.join(",");
        let ir = if with_ir {
            format!(r#","ir":{}"#, ir_text())
        } else {
            String::new()
        };
        run(&format!(r#"{{"steps":[{STEPS},{asks}]{ir}}}"#))
    }

    #[test]
    fn a_real_pizzas_run_answers_byte_for_byte_the_same_with_the_ir() {
        assert_eq!(answer(true), answer(false));
    }

    #[test]
    fn the_price_argument_is_gated_from_the_ir_not_the_generated_gate() {
        let args = Json::parse(r#"{"ceiling":{"cents":-5}}"#).unwrap_or(Json::Null);
        let gated = IrQueries::from_ir(&ir()).check_args("Pizzas::Order.CostingLessThan", &args);
        assert!(matches!(gated, Some(Err(_))));
    }

    #[test]
    fn the_run_holds_rows_and_refusals_so_the_comparison_means_something() {
        let text = answer(false);
        assert!(
            text.contains("Margherita") && text.contains("a price is never negative"),
            "{text}"
        );
    }
}

mod fallbacks {
    use super::*;

    fn domain(query: &str) -> Json {
        Json::parse(&format!(
            r#"{{"name":"D","aggregates":[{{"name":"A","attributes":[{{"name":"tag","type":"String"}},
            {{"name":"n","type":"Integer"}}],"value_objects":[],"entities":[],"queries":[{query}]}}]}}"#
        ))
        .unwrap_or(Json::Null)
    }

    fn lookup(query: &str) -> &'static str {
        match IrQueries::from_ir(&domain(query)).named("D::A.Q") {
            Lookup::Found(_) => "found",
            Lookup::Missing => "missing",
            Lookup::Generated => "generated",
        }
    }

    #[test]
    fn a_plain_where_is_read() {
        assert_eq!(
            lookup(r#"{"name":"Q","wheres":[{"field":"tag","op":"eq","value":"\"x\""}]}"#),
            "found"
        );
    }

    #[test]
    fn a_where_on_an_undeclared_field_has_no_row() {
        assert_eq!(
            lookup(r#"{"name":"Q","wheres":[{"field":"nope","op":"eq","value":"\"x\""}]}"#),
            "missing"
        );
    }

    #[test]
    fn a_list_literal_is_left_to_the_generated_path() {
        assert_eq!(
            lookup(r#"{"name":"Q","wheres":[{"field":"tag","op":"in","value":"[\"a\"]"}]}"#),
            "generated"
        );
    }

    #[test]
    fn an_ordered_comparison_against_text_has_no_row() {
        assert_eq!(
            lookup(r#"{"name":"Q","wheres":[{"field":"tag","op":"gt","value":"3"}]}"#),
            "missing"
        );
    }

    #[test]
    fn a_scalar_argument_of_the_wrong_shape_is_refused() {
        let ir = domain(
            r#"{"name":"Q","attributes":[{"name":"n","type":"Integer"}],"wheres":[{"field":"n","op":"eq","value":":n"}]}"#,
        );
        let args = Json::parse(r#"{"n":[1]}"#).unwrap_or(Json::Null);
        let refused = IrQueries::from_ir(&ir).check_args("D::A.Q", &args);
        assert!(matches!(refused, Some(Err(_))));
    }
}
