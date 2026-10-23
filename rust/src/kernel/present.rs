//! The kernel's `{"present": answer}` input: a run's answer turned into the bare shape a caller
//! is answered with, by the generated `present(aggregate, state)` router.
//!
//! It runs no step and touches no store. Only what a caller reads is presented: `instances`,
//! each event's `payload`, and each declared query's `rows`. Everything a host stores or replays
//! (`mutations`, `sagas`, `saga_snapshot`, ...) is left exactly as it came, because stored state
//! stays wrapped.

use super::Json;

/// The generated router's shape: one `"Domain::Aggregate"` state in, its bare shape out.
pub type Presenter = fn(&str, Json) -> Json;

/// Returns `answer` with its `instances`, event payloads and declared query rows presented
/// through `present`; every other key passes through verbatim.
pub fn present_answer(answer: Json, present: Presenter) -> Json {
    let Json::Object(fields) = answer else {
        return answer;
    };
    Json::Object(
        fields
            .into_iter()
            .map(|(key, value)| {
                let value = match key.as_str() {
                    "instances" => present_instances(value, present),
                    "events" => map_items(value, |event| present_event(event, present)),
                    "queries" => map_items(value, |entry| present_query(entry, present)),
                    _ => value,
                };
                (key, value)
            })
            .collect(),
    )
}

// `"Domain::Aggregate#id" => state`: the aggregate is the key up to its first `#`.
fn present_instances(instances: Json, present: Presenter) -> Json {
    let Json::Object(entries) = instances else {
        return instances;
    };
    Json::Object(
        entries
            .into_iter()
            .map(|(key, state)| {
                let aggregate = key.split_once('#').map_or(key.as_str(), |(head, _)| head);
                let state = present(aggregate, state);
                (key, state)
            })
            .collect(),
    )
}

fn present_event(event: Json, present: Presenter) -> Json {
    let Some(aggregate) = event
        .get("aggregate")
        .and_then(Json::as_str)
        .map(str::to_string)
    else {
        return event;
    };
    replace_field(event, "payload", |payload| present(&aggregate, payload))
}

// A declared query is named `"Domain::Aggregate.Query"`; its rows are that aggregate's state.
// A read model or an ad hoc filter names no aggregate this way, and the router passes an unknown
// name through, so its rows come back as they were.
fn present_query(entry: Json, present: Presenter) -> Json {
    let Some(aggregate) = entry
        .get("query")
        .and_then(Json::as_str)
        .and_then(|question| question.rsplit_once('.'))
        .map(|(head, _)| head.to_string())
    else {
        return entry;
    };
    replace_field(entry, "rows", |rows| {
        map_items(rows, |row| present(&aggregate, row))
    })
}

fn replace_field(object: Json, name: &str, f: impl Fn(Json) -> Json) -> Json {
    let Json::Object(fields) = object else {
        return object;
    };
    Json::Object(
        fields
            .into_iter()
            .map(|(key, value)| {
                let value = if key == name { f(value) } else { value };
                (key, value)
            })
            .collect(),
    )
}

fn map_items(list: Json, f: impl Fn(Json) -> Json) -> Json {
    match list {
        Json::Array(items) => Json::Array(items.into_iter().map(f).collect()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Stands in for the generated router: `Shop::Item` unwraps its `name` object to its
    // `value`; any other aggregate passes through, as the generated one does.
    fn shop_present(aggregate: &str, state: Json) -> Json {
        if aggregate != "Shop::Item" {
            return state;
        }
        replace_field(state, "name", |name| {
            name.get("value").cloned().unwrap_or(name)
        })
    }

    fn present(text: &str) -> String {
        present_answer(Json::parse(text).unwrap(), shop_present).to_json_string()
    }

    #[test]
    fn instances_are_presented_by_the_aggregate_their_key_names() {
        assert_eq!(
            present(
                r#"{"instances":{"Shop::Item#a":{"name":{"value":"x"}},"Other::Thing#b":{"name":{"value":"y"}}}}"#
            ),
            r#"{"instances":{"Shop::Item#a":{"name":"x"},"Other::Thing#b":{"name":{"value":"y"}}}}"#
        );
    }

    #[test]
    fn an_event_payload_is_presented_by_its_aggregate() {
        assert_eq!(
            present(
                r#"{"events":[{"name":"Named","aggregate":"Shop::Item","payload":{"name":{"value":"x"}}}]}"#
            ),
            r#"{"events":[{"name":"Named","aggregate":"Shop::Item","payload":{"name":"x"}}]}"#
        );
    }

    #[test]
    fn declared_query_rows_are_presented_by_the_aggregate_the_query_names() {
        assert_eq!(
            present(
                r#"{"queries":[{"query":"Shop::Item.All","rows":[{"id":"a","name":{"value":"x"}}],"reference_rows":[{"name":{"value":"x"}}]}]}"#
            ),
            r#"{"queries":[{"query":"Shop::Item.All","rows":[{"id":"a","name":"x"}],"reference_rows":[{"name":{"value":"x"}}]}]}"#
        );
    }

    #[test]
    fn mutations_sagas_and_refusals_pass_through_verbatim() {
        let text = r#"{"mutations":[[{"aggregate":"Shop::Item","state":{"name":{"value":"x"}}}]],"sagas":[],"refusals":[{"verb":"Shop::Item.Name","error":"no"}]}"#;
        assert_eq!(present(text), text);
    }
}

// Through `cli::run` and the generated pizzas router: what `{"present": answer}` answers for a
// real run's answer.
#[cfg(test)]
#[cfg(feature = "pizzas")]
mod pizzas_tests {
    use crate::kernel::cli::run;
    use crate::kernel::Json;

    const STEPS: &str = r#"{"steps":[
        {"verb":"Pizzas::Order.CreatePizza","with":{"name":"Margherita","pizza":{"price_cents":1200,"size":"large"}}},
        {"verb":"Pizzas::Order.AddTopping","to":"Margherita","with":{"topping":"basil","amount":2}},
        {"verb":"Pizzas::Order.Purchase","to":"Margherita","with":{"amount":1500,"customer_name":"Ann"}},
        {"query":"Pizzas::Order.Everything"}]}"#;

    fn answers() -> (Json, Json) {
        let answer = run(STEPS);
        let presented = run(&format!(r#"{{"present":{answer}}}"#));
        (
            Json::parse(&answer).unwrap(),
            Json::parse(&presented).unwrap(),
        )
    }

    fn text(value: Option<&Json>) -> String {
        value.map_or_else(|| "missing".to_string(), Json::to_json_string)
    }

    fn items<'a>(value: &'a Json, key: &str) -> &'a [Json] {
        value.get(key).and_then(Json::as_array).unwrap_or_default()
    }

    #[test]
    fn an_instance_answers_bare_and_a_multi_field_value_object_keeps_its_object() {
        let (_, presented) = answers();
        assert_eq!(
            text(presented.dig("instances.Pizzas::Order#Margherita")),
            r#"{"name":"Margherita","pizza":{"price_cents":1200,"size":"large"},"toppings":[{"name":"basil","amount":2}],"customer_name":"Ann","status":"sold"}"#
        );
    }

    #[test]
    fn each_event_payload_answers_bare_even_where_two_commands_type_one_name_apart() {
        let (_, presented) = answers();
        let payloads: Vec<String> = items(&presented, "events")
            .iter()
            .map(|event| text(event.get("payload")))
            .collect();
        assert_eq!(
            payloads,
            [
                r#"{"name":"Margherita","pizza":{"price_cents":1200,"size":"large"}}"#,
                r#"{"topping":"basil","amount":2}"#,
                r#"{"amount":1500,"customer_name":"Ann"}"#,
            ]
        );
    }

    #[test]
    fn a_declared_query_row_answers_bare() {
        let (_, presented) = answers();
        assert_eq!(
            text(items(&presented, "queries")[0].get("rows")),
            r#"[{"id":"Margherita","name":"Margherita","pizza":{"price_cents":1200,"size":"large"},"toppings":[{"name":"basil","amount":2}],"customer_name":"Ann","status":"sold"}]"#
        );
    }

    #[test]
    fn mutations_and_the_run_without_present_stay_wrapped() {
        let (answer, presented) = answers();
        assert_eq!(
            text(presented.get("mutations")),
            text(answer.get("mutations"))
        );
        assert_eq!(
            text(answer.dig("instances.Pizzas::Order#Margherita.name")),
            r#"{"value":"Margherita"}"#
        );
    }
}

#[cfg(test)]
#[cfg(feature = "tally")]
mod tally_tests {
    use crate::kernel::cli::run;
    use crate::kernel::Json;

    #[test]
    fn a_list_of_single_field_value_objects_answers_as_scalars_and_a_float_stays_one() {
        let answer = run(
            r#"{"steps":[{"verb":"Tallying::Tally.Open","with":{"tag":"a"}},
                {"verb":"Tallying::Tally.TagWith","to":"a","with":{"label":"red"}},
                {"verb":"Tallying::Tally.TagWith","to":"a","with":{"label":"blue"}}]}"#,
        );
        let presented =
            Json::parse_keeping_number_text(&run(&format!(r#"{{"present":{answer}}}"#))).unwrap();
        let tally = presented.dig("instances.Tallying::Tally#a").unwrap();
        assert_eq!(
            tally.get("tags").unwrap().to_json_string(),
            r#"["red","blue"]"#
        );
        assert_eq!(tally.get("weight").unwrap().to_json_string(), "0.0");
    }
}
