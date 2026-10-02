//! Facts a command `needs` (ADR 0081), answered before the argument gates read the arguments.
//!
//! The Ruby interpreter fills them in its `decode_arguments` step; here the same fill runs at the
//! head of `orchestrate`, ahead of `decode_aggregate_arguments`' own `decode_arguments` slot (the
//! first thing a dispatch does), so no step is added to the vocabulary. A fact is filled only
//! when the caller left the key out, so a supplied value wins.
//!
//! Which commands need what comes from the host's input, not from generated code: the input's
//! top-level `"needs"` is `{ "Domain::Aggregate.Command": [{"fact": "now", "type": "Integer"}] }`
//! (see `cli::run`). With no table installed nothing is filled and behavior is unchanged.
//!
//! The clock answers the step's `occurred_at` (the host stamps it once per step and journals it,
//! so a replay answers the same moment) and, with none, the system clock.

use super::Json;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;

/// One needed fact of a command: its name and the type of the command's attribute of that name.
#[derive(Debug, Clone, PartialEq)]
pub struct Need {
    pub fact: String,
    pub attribute_type: String,
}

thread_local! {
    static TABLE: RefCell<HashMap<String, Vec<Need>>> = RefCell::new(HashMap::new());
    static FIXED_CLOCK: Cell<Option<i64>> = const { Cell::new(None) };
}

/// Installs the table the host passed (an absent or malformed `"needs"` installs an empty one).
pub fn install(table: Option<&Json>) {
    let parsed = match table {
        Some(Json::Object(entries)) => entries
            .iter()
            .map(|(verb, needs)| {
                let needs = needs
                    .as_array()
                    .unwrap_or(&[])
                    .iter()
                    .filter_map(|n| {
                        let fact = n.get("fact")?.as_str()?.to_string();
                        let attribute_type = n.get("type").and_then(Json::as_str).unwrap_or("").to_string();
                        Some(Need { fact, attribute_type })
                    })
                    .collect();
                (verb.clone(), needs)
            })
            .collect(),
        _ => HashMap::new(),
    };
    TABLE.with(|t| *t.borrow_mut() = parsed);
}

/// Makes the kernel clock answer `secs` on this thread until cleared; the test seam.
pub fn fix_clock(secs: Option<i64>) {
    FIXED_CLOCK.with(|c| c.set(secs));
}

/// The clock's answer: epoch seconds, UTC. The step's `occurred_at` when it parses, else the
/// system clock (unless fixed).
pub fn now_secs(occurred_at: Option<&str>) -> i64 {
    if let Some(fixed) = FIXED_CLOCK.with(Cell::get) {
        return fixed;
    }
    occurred_at.and_then(parse_iso8601_utc).unwrap_or_else(|| {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or_default()
    })
}

/// `YYYY-MM-DDTHH:MM:SSZ` to epoch seconds (the format the host stamps).
fn parse_iso8601_utc(text: &str) -> Option<i64> {
    let text = text.strip_suffix('Z')?;
    let (date, time) = text.split_once('T')?;
    let mut d = date.split('-');
    let (y, m, day): (i64, i64, i64) = (d.next()?.parse().ok()?, d.next()?.parse().ok()?, d.next()?.parse().ok()?);
    let mut t = time.split(':');
    let (h, mi, s): (i64, i64, i64) = (t.next()?.parse().ok()?, t.next()?.parse().ok()?, t.next()?.split('.').next()?.parse().ok()?);
    // Howard Hinnant's days-from-civil.
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + h * 3600 + mi * 60 + s)
}

fn answer(need: &Need, occurred_at: Option<&str>) -> Option<Json> {
    match need.fact.as_str() {
        "now" => {
            let secs = now_secs(occurred_at);
            Some(if need.attribute_type == "Integer" { Json::int(secs) } else { Json::obj(vec![("value", Json::int(secs))]) })
        }
        _ => None,
    }
}

/// `args` with each fact `verb` needs and the caller left out answered, or `None` when nothing
/// needed filling (no needs, or every fact supplied). Reads `with` when the call carries one,
/// else the flat object, as `CommandInvocation` does.
pub fn enrich(verb: &str, args: &Json, occurred_at: Option<&str>) -> Option<Json> {
    let needs = TABLE.with(|t| t.borrow().get(verb).cloned())?;
    let explicit = matches!(args.get("with"), Some(Json::Object(_)));
    let facts = if explicit { args.get("with")? } else { args };
    let Json::Object(held) = facts else { return None };
    let mut filled = held.clone();
    let before = filled.len();
    for need in &needs {
        if held.iter().any(|(k, _)| k == &need.fact) {
            continue;
        }
        if let Some(value) = answer(need, occurred_at) {
            filled.push((need.fact.clone(), value));
        }
    }
    if filled.len() == before {
        return None;
    }
    if !explicit {
        return Some(Json::Object(filled));
    }
    let Json::Object(envelope) = args else { return None };
    Some(Json::Object(envelope.iter().map(|(k, v)| if k == "with" { (k.clone(), Json::Object(filled.clone())) } else { (k.clone(), v.clone()) }).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table() -> Json {
        Json::parse(
            r#"{"D::A.Instant": [{"fact": "now", "type": "LeaseInstant"}],
                "D::A.Seconds": [{"fact": "now", "type": "Integer"}]}"#,
        )
        .unwrap()
    }

    fn with(fields: Vec<(&str, Json)>) -> Json {
        Json::obj(vec![("with", Json::obj(fields))])
    }

    #[test]
    fn a_needed_fact_left_out_is_answered_by_the_clock() {
        install(Some(&table()));
        fix_clock(Some(1_700_000_000));
        let filled = enrich("D::A.Instant", &with(vec![("x", Json::int(1))]), None).unwrap();
        assert_eq!(filled.get("with").unwrap().get("now"), Some(&Json::obj(vec![("value", Json::int(1_700_000_000))])));
        assert_eq!(filled.get("with").unwrap().get("x"), Some(&Json::int(1)));
    }

    #[test]
    fn a_supplied_value_is_kept() {
        install(Some(&table()));
        fix_clock(Some(1));
        let args = with(vec![("now", Json::obj(vec![("value", Json::int(42))]))]);
        assert_eq!(enrich("D::A.Instant", &args, None), None);
    }

    #[test]
    fn a_command_with_no_needs_is_untouched() {
        install(Some(&table()));
        assert_eq!(enrich("D::A.Plain", &with(vec![]), None), None);
        install(None);
        assert_eq!(enrich("D::A.Instant", &with(vec![]), None), None);
    }

    #[test]
    fn an_integer_attribute_gets_a_bare_integer_and_an_instant_a_value_object() {
        install(Some(&table()));
        fix_clock(Some(9));
        assert_eq!(enrich("D::A.Seconds", &with(vec![]), None).unwrap().get("with").unwrap().get("now"), Some(&Json::int(9)));
        assert_eq!(
            enrich("D::A.Instant", &with(vec![]), None).unwrap().get("with").unwrap().get("now"),
            Some(&Json::obj(vec![("value", Json::int(9))]))
        );
    }

    #[test]
    fn a_flat_invocation_is_filled_at_the_top_level() {
        install(Some(&table()));
        fix_clock(Some(5));
        let filled = enrich("D::A.Seconds", &Json::obj(vec![("x", Json::int(1))]), None).unwrap();
        assert_eq!(filled.get("now"), Some(&Json::int(5)));
    }

    #[test]
    fn the_step_s_occurred_at_is_the_answer_when_no_clock_is_fixed() {
        fix_clock(None);
        assert_eq!(now_secs(Some("2023-11-14T22:13:20Z")), 1_700_000_000);
        assert_eq!(now_secs(Some("1970-01-01T00:00:00Z")), 0);
        assert!(now_secs(None) > 1_700_000_000);
    }
}
