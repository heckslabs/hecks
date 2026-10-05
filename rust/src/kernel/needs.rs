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
    static DEFAULTS: RefCell<HashMap<String, Vec<(String, Json)>>> = RefCell::new(HashMap::new());
    static QUERY_TABLE: RefCell<HashMap<String, Vec<Need>>> = RefCell::new(HashMap::new());
    static FIXED_CLOCK: Cell<Option<i64>> = const { Cell::new(None) };
}

/// Reads a `{ name: [{fact, type}] }` table (an absent or malformed one reads as empty).
fn parse_table(table: Option<&Json>) -> HashMap<String, Vec<Need>> {
    match table {
        Some(Json::Object(entries)) => entries
            .iter()
            .map(|(name, needs)| {
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
                (name.clone(), needs)
            })
            .collect(),
        _ => HashMap::new(),
    }
}

/// Installs the table the host passed, command verb to its needs (an absent or malformed
/// `"needs"` installs an empty one).
pub fn install(table: Option<&Json>) {
    TABLE.with(|t| *t.borrow_mut() = parse_table(table));
}

/// Installs the table of queries that need a fact, `"Domain::Aggregate.Query"` to its needs. Kept
/// apart from the commands': a command and a query may share a qualified name.
pub fn install_queries(table: Option<&Json>) {
    QUERY_TABLE.with(|t| *t.borrow_mut() = parse_table(table));
}

/// Installs the declared defaults the host passed, `{ verb: { attribute: value } }` (an absent or
/// malformed `"defaults"` installs an empty table). They fill after the needs, so a fact that is
/// both needed and defaulted takes the answer.
pub fn install_defaults(table: Option<&Json>) {
    let parsed = match table {
        Some(Json::Object(entries)) => entries
            .iter()
            .filter_map(|(verb, attributes)| match attributes {
                Json::Object(held) => Some((verb.clone(), held.clone())),
                _ => None,
            })
            .collect(),
        _ => HashMap::new(),
    };
    DEFAULTS.with(|t| *t.borrow_mut() = parsed);
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
        // `now` is epoch seconds; `today` the day those fall in, whole days since the epoch (UTC).
        "now" | "today" => {
            let secs = now_secs(occurred_at);
            let answer = if need.fact == "today" { secs.div_euclid(86_400) } else { secs };
            Some(if need.attribute_type == "Integer" { Json::int(answer) } else { Json::obj(vec![("value", Json::int(answer))]) })
        }
        _ => None,
    }
}

/// `args` with each fact `verb` needs and the caller left out answered, or `None` when nothing
/// needed filling (no needs, or every fact supplied). Reads `with` when the call carries one,
/// else the flat object, as `CommandInvocation` does.
pub fn enrich(verb: &str, args: &Json, occurred_at: Option<&str>) -> Option<Json> {
    let needs = TABLE.with(|t| t.borrow().get(verb).cloned()).unwrap_or_default();
    let defaults = DEFAULTS.with(|t| t.borrow().get(verb).cloned()).unwrap_or_default();
    if needs.is_empty() && defaults.is_empty() {
        return None;
    }
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
    for (name, value) in &defaults {
        if !filled.iter().any(|(k, _)| k == name) {
            filled.push((name.clone(), value.clone()));
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

/// `args` with each fact the query `question` needs and the caller left out answered, or `None`
/// when nothing needed filling (the query needs nothing, or every fact is supplied). A query's
/// arguments are the flat object of its step.
pub fn enrich_query(question: &str, args: &Json, occurred_at: Option<&str>) -> Option<Json> {
    let needs = QUERY_TABLE.with(|t| t.borrow().get(question).cloned())?;
    let Json::Object(held) = args else { return None };
    let mut filled = held.clone();
    for need in &needs {
        if held.iter().any(|(k, _)| k == &need.fact) {
            continue;
        }
        if let Some(value) = answer(need, occurred_at) {
            filled.push((need.fact.clone(), value));
        }
    }
    if filled.len() == held.len() {
        return None;
    }
    Some(Json::Object(filled))
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

    fn defaults() -> Json {
        Json::parse(r#"{"D::A.Start": {"runs": 30}, "D::A.Instant": {"holder": "nobody"}}"#).unwrap()
    }

    #[test]
    fn an_omitted_argument_takes_its_declared_default() {
        install(None);
        install_defaults(Some(&defaults()));
        let filled = enrich("D::A.Start", &with(vec![("ref", Json::int(1))]), None).unwrap();
        assert_eq!(filled.get("with").unwrap().get("runs"), Some(&Json::int(30)));
        assert_eq!(filled.get("with").unwrap().get("ref"), Some(&Json::int(1)));
    }

    #[test]
    fn a_supplied_argument_keeps_its_value_over_the_default() {
        install(None);
        install_defaults(Some(&defaults()));
        assert_eq!(enrich("D::A.Start", &with(vec![("runs", Json::int(7))]), None), None);
    }

    #[test]
    fn a_flat_invocation_is_filled_at_its_top_level() {
        install(None);
        install_defaults(Some(&defaults()));
        let filled = enrich("D::A.Start", &Json::obj(vec![("ref", Json::int(1))]), None).unwrap();
        assert_eq!(filled.get("runs"), Some(&Json::int(30)));
    }

    #[test]
    fn a_needed_fact_is_answered_and_the_default_fills_beside_it() {
        install(Some(&table()));
        install_defaults(Some(&defaults()));
        fix_clock(Some(3));
        let filled = enrich("D::A.Instant", &with(vec![]), None).unwrap();
        assert_eq!(filled.get("with").unwrap().get("now"), Some(&Json::obj(vec![("value", Json::int(3))])));
        assert_eq!(filled.get("with").unwrap().get("holder"), Some(&Json::str("nobody")));
        fix_clock(None);
    }

    #[test]
    fn no_installed_defaults_leaves_a_command_untouched() {
        install(None);
        install_defaults(None);
        assert_eq!(enrich("D::A.Start", &with(vec![]), None), None);
    }

    fn query_table() -> Json {
        Json::parse(
            r#"{"D::A.Expired": [{"fact": "now", "type": "Integer"}],
                "D::A.Today": [{"fact": "today", "type": "DayNumber"}]}"#,
        )
        .unwrap()
    }

    #[test]
    fn a_needed_query_fact_the_caller_left_out_is_answered_by_the_clock() {
        install_queries(Some(&query_table()));
        fix_clock(Some(1_700_000_000));
        let filled = enrich_query("D::A.Expired", &Json::obj(vec![]), None).unwrap();
        assert_eq!(filled.get("now"), Some(&Json::int(1_700_000_000)));
        fix_clock(None);
        install_queries(None);
    }

    #[test]
    fn a_query_value_the_caller_supplied_is_kept() {
        install_queries(Some(&query_table()));
        fix_clock(Some(1));
        assert_eq!(enrich_query("D::A.Expired", &Json::obj(vec![("now", Json::int(7))]), None), None);
        fix_clock(None);
        install_queries(None);
    }

    #[test]
    fn a_query_that_needs_nothing_is_untouched() {
        install_queries(Some(&query_table()));
        assert_eq!(enrich_query("D::A.Plain", &Json::obj(vec![]), None), None);
        install_queries(None);
        assert_eq!(enrich_query("D::A.Expired", &Json::obj(vec![]), None), None);
    }

    #[test]
    fn a_command_and_a_query_of_one_name_keep_their_own_needs() {
        install(Some(&table()));
        install_queries(Some(&query_table()));
        fix_clock(Some(5));
        assert_eq!(enrich_query("D::A.Instant", &Json::obj(vec![]), None), None);
        assert!(enrich("D::A.Instant", &with(vec![]), None).is_some());
        fix_clock(None);
        install(None);
        install_queries(None);
    }

    #[test]
    fn today_is_the_day_the_clock_falls_in_whole_days_since_the_epoch() {
        install_queries(Some(&query_table()));
        fix_clock(Some((19_000 * 86_400) + 86_399));
        let filled = enrich_query("D::A.Today", &Json::obj(vec![]), None).unwrap();
        assert_eq!(filled.get("today"), Some(&Json::obj(vec![("value", Json::int(19_000))])));
        fix_clock(Some(19_001 * 86_400));
        let next = enrich_query("D::A.Today", &Json::obj(vec![]), None).unwrap();
        assert_eq!(next.get("today"), Some(&Json::obj(vec![("value", Json::int(19_001))])));
        fix_clock(None);
        install_queries(None);
    }
}
