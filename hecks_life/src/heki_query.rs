//! HekiQuery — filter / order / project logic for .heki stores
//!
//! Pure functions over `heki::Store`. No IO — the CLI is responsible for
//! reading the store and printing the result. This module is the
//! engine room the new `heki list / count / mark / next-ref / ...`
//! subcommands share.
//!
//! [antibody-exempt: hecks-life heki subcommand expansion; prerequisite
//!  for i37 Phase B (replace python3 -c invocations in shell scripts).
//!  Retires when heki dispatch moves to a bluebook + hecksagon.]
//!
//! Usage:
//!   let filter = Filter::parse("status=queued")?;
//!   let records = filter_records(&store, &[filter]);
//!   let ordered = order_records(records, &OrderSpec::parse("priority:enum=high,medium,normal,low")?);
//!
//! Filter ops (derived from shell python patterns):
//!   k=v    exact equality (string compare on the JSON stringified value)
//!   k!=v   not equal
//!   k~=v   prefix match
//!   k*=v   substring match
//!
//! Order spec:
//!   field                    — ascending
//!   field:asc / field:desc   — explicit direction
//!   field:enum=a,b,c         — explicit enum ordering (a first, c last)
//!   Ties on primary key break on created_at (stable byte-for-byte).

use crate::heki::{Record, Store};

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum FilterOp { Eq, NotEq, Prefix, Substring }

#[derive(Debug, Clone)]
pub struct Filter {
    pub field: String,
    pub op: FilterOp,
    pub value: String,
}

impl Filter {
    /// Parse a `--where k=v` / `k!=v` / `k~=v` / `k*=v` spec.
    /// Returns Err with a message on syntax error (exit code 2 territory).
    pub fn parse(spec: &str) -> Result<Self, String> {
        // Order matters — check two-char ops before '='.
        if let Some(i) = spec.find("!=") {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::NotEq,
                value: spec[i+2..].to_string(),
            });
        }
        if let Some(i) = spec.find("~=") {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::Prefix,
                value: spec[i+2..].to_string(),
            });
        }
        if let Some(i) = spec.find("*=") {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::Substring,
                value: spec[i+2..].to_string(),
            });
        }
        if let Some(i) = spec.find('=') {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::Eq,
                value: spec[i+1..].to_string(),
            });
        }
        Err(format!("invalid --where spec: {}", spec))
    }

    pub fn matches(&self, rec: &Record) -> bool {
        let val = field_to_string(rec.get(&self.field));
        match self.op {
            FilterOp::Eq        => val == self.value,
            FilterOp::NotEq     => val != self.value,
            FilterOp::Prefix    => val.starts_with(&self.value),
            FilterOp::Substring => val.contains(&self.value),
        }
    }
}

/// Apply every filter with AND semantics.
pub fn filter_records<'a>(store: &'a Store, filters: &[Filter]) -> Vec<&'a Record> {
    store.values()
        .filter(|r| filters.iter().all(|f| f.matches(r)))
        .collect()
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum OrderDir { Asc, Desc }

#[derive(Debug, Clone)]
pub struct OrderSpec {
    pub field: String,
    pub dir: OrderDir,
    /// Explicit enum mapping — position in this vec is the sort key.
    /// Values not in the list sort after all listed values.
    pub enum_order: Option<Vec<String>>,
    /// When true, strip a leading alphabetic prefix and sort the
    /// trailing number. Lets `--order ref:numeric_ref` sort i2 < i10
    /// (matches the `int(v.get('ref','i999')[1:])` Python pattern in
    /// inbox.sh).
    pub numeric_ref: bool,
}

impl OrderSpec {
    /// Parse a `--order <field>[:asc|desc|enum=a,b,c]` spec.
    pub fn parse(spec: &str) -> Result<Self, String> {
        let (field, rest) = match spec.find(':') {
            Some(i) => (&spec[..i], Some(&spec[i+1..])),
            None    => (spec, None),
        };
        let field = field.to_string();
        if field.is_empty() {
            return Err(format!("invalid --order spec: {}", spec));
        }
        match rest {
            None => Ok(OrderSpec { field, dir: OrderDir::Asc, enum_order: None, numeric_ref: false }),
            Some("asc")  => Ok(OrderSpec { field, dir: OrderDir::Asc,  enum_order: None, numeric_ref: false }),
            Some("desc") => Ok(OrderSpec { field, dir: OrderDir::Desc, enum_order: None, numeric_ref: false }),
            Some("numeric_ref") => Ok(OrderSpec {
                field, dir: OrderDir::Asc, enum_order: None, numeric_ref: true,
            }),
            Some(e) if e.starts_with("enum=") => {
                let list = e[5..].split(',').map(|s| s.to_string()).collect();
                Ok(OrderSpec { field, dir: OrderDir::Asc, enum_order: Some(list), numeric_ref: false })
            }
            Some(other) => Err(format!("invalid --order modifier: {}", other)),
        }
    }

    fn key(&self, rec: &Record) -> OrderKey {
        let raw = field_to_string(rec.get(&self.field));
        if let Some(list) = &self.enum_order {
            let idx = list.iter().position(|v| v == &raw).unwrap_or(list.len());
            return OrderKey::Int(idx as i64);
        }
        if self.numeric_ref {
            // Strip leading alphabetic chars, parse the tail as int.
            // Missing / unparseable refs get a very large number so they
            // sort last — matches the Python `or 999`.
            let tail: String = raw.chars().skip_while(|c| c.is_alphabetic()).collect();
            return match tail.parse::<i64>() {
                Ok(n) => OrderKey::Int(n),
                Err(_) => OrderKey::Int(i64::MAX),
            };
        }
        if let Ok(n) = raw.parse::<i64>() {
            OrderKey::Int(n)
        } else if let Ok(f) = raw.parse::<f64>() {
            OrderKey::Float(f)
        } else {
            OrderKey::Str(raw)
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum OrderKey { Int(i64), Float(f64), Str(String) }

impl Eq for OrderKey {}
impl PartialOrd for OrderKey { fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(o)) } }
impl Ord for OrderKey {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        match (self, o) {
            (OrderKey::Int(a),   OrderKey::Int(b))   => a.cmp(b),
            (OrderKey::Float(a), OrderKey::Float(b)) => a.partial_cmp(b).unwrap_or(Ordering::Equal),
            (OrderKey::Int(a),   OrderKey::Float(b)) => (*a as f64).partial_cmp(b).unwrap_or(Ordering::Equal),
            (OrderKey::Float(a), OrderKey::Int(b))   => a.partial_cmp(&(*b as f64)).unwrap_or(Ordering::Equal),
            (OrderKey::Str(a),   OrderKey::Str(b))   => a.cmp(b),
            // Mixed types: numeric < string.
            (OrderKey::Int(_),   OrderKey::Str(_))   => Ordering::Less,
            (OrderKey::Float(_), OrderKey::Str(_))   => Ordering::Less,
            (OrderKey::Str(_),   OrderKey::Int(_))   => Ordering::Greater,
            (OrderKey::Str(_),   OrderKey::Float(_)) => Ordering::Greater,
        }
    }
}

/// Order a slice of record refs in place according to the spec. Ties on
/// the primary key break on created_at ascending — stable byte-for-byte
/// output across runs.
pub fn order_records<'a>(recs: Vec<&'a Record>, spec: &OrderSpec) -> Vec<&'a Record> {
    order_records_multi(recs, std::slice::from_ref(spec))
}

/// Multi-key ordering. Each spec applies left-to-right; the first tie
/// breaks on the second, and so on. Final tie-break is created_at ASC.
pub fn order_records_multi<'a>(mut recs: Vec<&'a Record>, specs: &[OrderSpec]) -> Vec<&'a Record> {
    recs.sort_by(|a, b| {
        for spec in specs {
            let ka = spec.key(a);
            let kb = spec.key(b);
            let cmp = ka.cmp(&kb);
            let cmp = if spec.dir == OrderDir::Desc { cmp.reverse() } else { cmp };
            if cmp != std::cmp::Ordering::Equal { return cmp; }
        }
        let ca = field_to_string(a.get("created_at"));
        let cb = field_to_string(b.get("created_at"));
        ca.cmp(&cb)
    });
    recs
}

// ---------------------------------------------------------------------------
// Projection helpers
// ---------------------------------------------------------------------------

/// Render a scalar JSON value as a plain string. Strings lose their
/// quotes (shell-friendly); numbers/bools stringify themselves; nulls
/// become "". Objects/arrays compact-JSON.
pub fn field_to_string(v: Option<&serde_json::Value>) -> String {
    match v {
        None                               => String::new(),
        Some(serde_json::Value::Null)      => String::new(),
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Bool(b))   => b.to_string(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(other)                        => other.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::heki::Record;
    use serde_json::json;

    fn rec(pairs: &[(&str, serde_json::Value)]) -> Record {
        pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
    }

    #[test]
    fn filter_parses_all_ops() {
        assert_eq!(Filter::parse("a=b").unwrap().op,  FilterOp::Eq);
        assert_eq!(Filter::parse("a!=b").unwrap().op, FilterOp::NotEq);
        assert_eq!(Filter::parse("a~=b").unwrap().op, FilterOp::Prefix);
        assert_eq!(Filter::parse("a*=b").unwrap().op, FilterOp::Substring);
        assert!(Filter::parse("nope").is_err());
    }

    #[test]
    fn eq_and_neq_match_on_string_fields() {
        let r = rec(&[("status", json!("queued"))]);
        assert!(Filter::parse("status=queued").unwrap().matches(&r));
        assert!(!Filter::parse("status=done").unwrap().matches(&r));
        assert!(Filter::parse("status!=done").unwrap().matches(&r));
    }

    #[test]
    fn prefix_and_substring_ops() {
        let r = rec(&[("ref", json!("i42"))]);
        assert!(Filter::parse("ref~=i").unwrap().matches(&r));
        assert!(Filter::parse("ref*=4").unwrap().matches(&r));
        assert!(!Filter::parse("ref~=x").unwrap().matches(&r));
    }

    #[test]
    fn order_spec_parses_enum() {
        let o = OrderSpec::parse("priority:enum=high,low").unwrap();
        assert_eq!(o.field, "priority");
        assert_eq!(o.enum_order, Some(vec!["high".into(), "low".into()]));
    }

    #[test]
    fn enum_order_sorts_deterministically() {
        let r_low  = rec(&[("priority", json!("low"))]);
        let r_high = rec(&[("priority", json!("high"))]);
        let r_med  = rec(&[("priority", json!("medium"))]);
        let store: Store = vec![
            ("a".into(), r_low), ("b".into(), r_high), ("c".into(), r_med),
        ].into_iter().collect();
        let spec = OrderSpec::parse("priority:enum=high,medium,low").unwrap();
        let sorted = order_records(store.values().collect(), &spec);
        let names: Vec<_> = sorted.iter().map(|r| field_to_string(r.get("priority"))).collect();
        assert_eq!(names, vec!["high", "medium", "low"]);
    }

    #[test]
    fn numeric_order_sorts_by_value_not_lexicographically() {
        let s: Store = vec![
            ("a".into(), rec(&[("n", json!(2))])),
            ("b".into(), rec(&[("n", json!(10))])),
            ("c".into(), rec(&[("n", json!(1))])),
        ].into_iter().collect();
        let spec = OrderSpec::parse("n").unwrap();
        let sorted = order_records(s.values().collect(), &spec);
        let ns: Vec<_> = sorted.iter().map(|r| field_to_string(r.get("n"))).collect();
        assert_eq!(ns, vec!["1", "2", "10"]);
    }

    #[test]
    fn ties_break_on_created_at() {
        let r1 = rec(&[("p", json!("a")), ("created_at", json!("2026-04-21T00:00:00Z"))]);
        let r2 = rec(&[("p", json!("a")), ("created_at", json!("2026-04-21T00:00:01Z"))]);
        let s: Store = vec![("b".into(), r2), ("a".into(), r1)].into_iter().collect();
        let spec = OrderSpec::parse("p").unwrap();
        let sorted = order_records(s.values().collect(), &spec);
        let cas: Vec<_> = sorted.iter().map(|r| field_to_string(r.get("created_at"))).collect();
        assert_eq!(cas, vec!["2026-04-21T00:00:00Z", "2026-04-21T00:00:01Z"]);
    }
}
