// HAND-MAINTAINED — GRADUATED OUT OF bin/project_kernel_capabilities'S
// GENERATED-GAP-ENUM TREATMENT.
//
// Until this change, this file's own header (and bin/project_kernel_
// capabilities's own, matching header) said plainly: "QueryComparator has
// NO [dispatch] site... this enum is generated and NOTHING in this crate
// matches over it... Add a real dispatch site against this enum the day
// that day comes, and it will already refuse to compile non-exhaustively."
// This is that day — for exactly ONE real slice of the query engine, not
// the whole of it. `rust/src/kernel/cli.rs`'s own header explains the
// two shapes a "query" step can take on the wire and which one actually
// dispatches here.
//
// Because a real dispatch site now exists, `bin/project_kernel_
// capabilities` no longer regenerates this file (see its own header,
// where that decision is made and explained). The eight variant NAMES
// are still exactly `Hecksagain::QuerySpecification::Common::COMPARATORS`
// (lib/hecksagain/query_specification/common/comparators.rb) — the same
// set `Vocabulary::QueryComparator` (language/bluebook/vocabulary.bluebook)
// declares and spec/vocabulary_conformance_spec holds the runtime to.
// That ground truth didn't change; only who's responsible for keeping
// this file in sync with it did — a human, now, the same way every OTHER
// hand-written interpretation file under rust/src/kernel/ already is.
//
// GROUND TRUTH FOR THE MATCHING LOGIC ITSELF, read directly rather than
// guessed at: `Ports::Query::InMemory#holds?` (lib/hecksagain/ports/
// query/in_memory.rb) — the engine that actually answers a memory-backed
// aggregate's query in Ruby, and the same shape `QueryInterpreter#holds?`
// (lib/hecksagain/runtime/query_interpreter.rb) deliberately duplicates
// byte-for-byte for entity/sub-list queries and the fuzzer's own
// reference oracle (that file's own comment: kept identical on purpose).
// Proven against REAL, adversarially-picked cases, not merely read:
// spec/query_comparators_spec.rb exercises all eight comparators against
// the real banking bluebook (its own header: gt/gte/lt/lte/ne/in/contains
// were once silently treated as `eq` in both engines until a fixture
// caught it), and spec/adapters/query_agreement_spec.rb cross-checks
// Memory, Sqlite, Postgres, and (when reachable) D1 against independently
// hand-computed expected id lists for the same comparator family.
//
// WHAT DISPATCHES HERE, TODAY: `kernel/cli.rs`'s ad hoc, single-clause
// "query" step — the OBJECT form, `{"aggregate", "field", "op", "value"}`
// — via `repository.rs`'s `filter_entries`. ALSO, as of `rust/project/
// queries.rb`/`kernel/named_query.rs`: a NAMED/declared bluebook
// `query "X" do ... end` ask — the STRING form of the same "query" step —
// for the subset expressible as one or more field-comparator conditions
// against a single aggregate's OWN attributes, via the exact same
// `QueryComparator`/`filter_entries` this file and repository.rs already
// implement, just with the query's own conditions baked in by a generator
// instead of supplied ad hoc over the wire. `IR::ReadModel` (a
// cross-aggregate ask — `rust/project/domain_generator.rb`'s own
// "whole_kind" `read_model` tracking, `bin/rust_coverage`'s own header)
// and a declared query that itself needs `order_by`/`limit`/a reference
// hop/a type-unrecoverable literal comparator are the REMAINING gap —
// `rust/project/queries.rb`'s own header has the full argument for why
// each of those specifically stays ungenerated rather than forced.

use super::Json;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryComparator {
    Eq,
    Ne,
    Gt,
    Gte,
    Lt,
    Lte,
    In,
    Contains,
}

impl QueryComparator {
    pub const ALL: &'static [QueryComparator] = &[
        QueryComparator::Eq,
        QueryComparator::Ne,
        QueryComparator::Gt,
        QueryComparator::Gte,
        QueryComparator::Lt,
        QueryComparator::Lte,
        QueryComparator::In,
        QueryComparator::Contains,
    ];

    /// The wire's `op` string, read against the closed set — `None` for
    /// anything else. Ruby's own `holds?` has no equivalent gate: its
    /// `case clause.op.to_s ... else held == want` end can only ever see
    /// one of the eight names in real use, because a declared
    /// where-clause's `op:` is validated at BLUEBOOK DECLARE TIME
    /// (`admits: "Vocabulary::QueryComparator"`) long before any record
    /// is ever asked about — that `else` arm is dead code for a real
    /// declared query, reachable only by a bug in the interpreter itself.
    /// This wire protocol has no declare-time gate at all (a caller can
    /// put any string in `"op"`), so unlike Ruby's own fallback, an
    /// unrecognized comparator here REFUSES (`kernel/cli.rs` turns
    /// `None` into `Refusal::TypeMismatch`) rather than silently
    /// defaulting to `eq` — a case Ruby's own `else` exists to be
    /// unreachable FOR, not one this looser protocol should let a typo
    /// pass through silently.
    pub fn parse(op: &str) -> Option<Self> {
        match op {
            "eq" => Some(QueryComparator::Eq),
            "ne" => Some(QueryComparator::Ne),
            "gt" => Some(QueryComparator::Gt),
            "gte" => Some(QueryComparator::Gte),
            "lt" => Some(QueryComparator::Lt),
            "lte" => Some(QueryComparator::Lte),
            "in" => Some(QueryComparator::In),
            "contains" => Some(QueryComparator::Contains),
            _ => None,
        }
    }

    /// `Ports::Query::InMemory#holds?`, ported directly. `held`/`want`
    /// arrive ALREADY reduced through `comparable` (below) — matching
    /// Ruby's own contract exactly: `holds?(clause, held, args)` never
    /// re-digs a field or re-resolves an argument itself, its caller
    /// does that once, up front (`repository.rs`'s `filter_entries`).
    pub fn matches(self, held: &Json, want: &Json) -> bool {
        match self {
            QueryComparator::Eq => held == want,
            QueryComparator::Ne => held != want,
            QueryComparator::Gt => ordered(held, want) && as_f64(held) > as_f64(want),
            QueryComparator::Gte => ordered(held, want) && as_f64(held) >= as_f64(want),
            QueryComparator::Lt => ordered(held, want) && as_f64(held) < as_f64(want),
            QueryComparator::Lte => ordered(held, want) && as_f64(held) <= as_f64(want),
            QueryComparator::In => members(want).iter().any(|member| member == &to_s(held)),
            QueryComparator::Contains => contains(held, want),
        }
    }
}

/// gt/gte/lt/lte are numeric-only and silently FALSE otherwise — ported
/// from `Ports::Query::InMemory.ordered?`/`QueryInterpreter#ordered?`
/// verbatim. A where-clause never raises the way a `given` does, so a
/// comparator asked to order a String (or a `nil`/`Json::Null`) just
/// answers "no match" for every record it's asked about, not a refusal —
/// this is the real, proven TYPE-MISMATCH behavior (that file's own
/// comment: "lt was already exactly this permissive"), not an assumption.
fn ordered(held: &Json, want: &Json) -> bool {
    matches!(held, Json::Num(_)) && matches!(want, Json::Num(_))
}

/// Only ever called once `ordered` has already gated the comparison —
/// the NaN fallback below is unreachable in practice, kept rather than
/// `unwrap`ing so this stays a total function like everything else in
/// this kernel, never a panic over a comparator this crate's own JSON
/// parser could never actually hand it (a non-`Num` `Json` value).
fn as_f64(value: &Json) -> f64 {
    match value {
        Json::Num(n) => *n,
        _ => f64::NAN,
    }
}

/// Ruby's own `#to_s` on a comparator's held/wanted SCALAR — only ever
/// called on a value `comparable` (below) has already reduced to a
/// scalar, except inside `members`, which maps it over an Array's own
/// elements (a `list_of` field's members, each comparable-reduced
/// individually first, the same as a bare scalar field already is).
fn to_s(value: &Json) -> String {
    match value {
        Json::Str(s) => s.clone(),
        Json::Num(n) if n.fract() == 0.0 && n.abs() < 1e15 => (*n as i64).to_string(),
        Json::Num(n) => n.to_string(),
        Json::Bool(b) => b.to_string(),
        Json::Null => String::new(),
        // Array/Object: `comparable` already collapses every ORDINARY
        // held/want value before this is ever reached; a multi-member
        // value object with no numeric member is the one real case that
        // still arrives structured here. `to_json_string` is a
        // reasonable, non-panicking stand-in for Ruby's own `Hash#to_s`
        // — this kernel has no exact equivalent and none of the corpus's
        // real queries land here.
        other => other.to_json_string(),
    }
}

/// `Ports::Query::InMemory#comparable`, ported directly. ONE LEVEL ONLY
/// — it does not recurse into a nested value object's own nested value
/// objects, matching Ruby exactly (comparable is applied fresh to each
/// dug field, never chained): a numeric member wins if the value object
/// carries one (`Money{cents, currency}` reduces to `cents`); otherwise a
/// genuinely single-member value object (`AccountNumber{value}`) reduces
/// to that one member; anything else — a multi-member, non-numeric value
/// object, or a value that was never an object at all (a plain scalar,
/// or a `list_of`'s own Array) — passes through unchanged.
pub fn comparable(value: &Json) -> Json {
    let Json::Object(fields) = value else { return value.clone() };

    if let Some((_, numeric)) = fields.iter().find(|(_, v)| matches!(v, Json::Num(_))) {
        return numeric.clone();
    }
    if fields.len() == 1 {
        return fields[0].1.clone();
    }
    value.clone()
}

/// `in`'s own reading of ITS ARGUMENT (`want`), and `contains`'s reading
/// of a `list_of` field's STORED value (`held`) — ported from
/// `Ports::Query::InMemory#members`. A real JSON array survives as
/// elements, each reduced through `comparable` before stringifying (the
/// same unwrapping a lone scalar field already gets); anything else —
/// text a caller passed meaning "any of these," per `in`'s own contract —
/// is read as comma-separated.
fn members(value: &Json) -> Vec<String> {
    if let Json::Array(items) = value {
        return items.iter().map(|item| to_s(&comparable(item))).collect();
    }
    to_s(value).split(',').map(|piece| piece.trim().to_string()).collect()
}

/// `contains` means two different things depending on what's HELD — real
/// element membership for a `list_of` field (already a genuine JSON
/// array with nothing to split), plain substring for anything else.
/// Ported from `Ports::Query::InMemory#contains?` — matching SQL's own
/// `instr`/`position` reading of a scalar field's real comma, per that
/// method's own header, rather than silently treating a free-text
/// field's comma as a separator the way this once (wrongly) did.
fn contains(held: &Json, want: &Json) -> bool {
    if matches!(held, Json::Array(_)) {
        return members(held).iter().any(|member| member == &to_s(want));
    }
    to_s(held).contains(&to_s(want))
}
