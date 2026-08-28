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
// where that decision is made and explained). The variant NAMES are
// still exactly `Hecks::QuerySpecification::Common::COMPARATORS`
// (lib/hecks/query_specification/common/comparators.rb) — the same
// set `Vocabulary::QueryComparator` (language/bluebook/vocabulary.bluebook)
// declares and spec/vocabulary_conformance_spec holds the runtime to. NINE
// now, not eight — `NoneInState` (item #9, whole-project table-
// unification survey) closed the gap this header used to describe: for a
// long stretch, `Vocabulary::QueryComparator` had already grown a ninth
// name (`none_in_state`, "a vendored addition" per vocabulary.bluebook's
// own comment) that this enum simply never caught up to. That ground
// truth didn't change; only who's responsible for keeping this file in
// sync with it did — a human, now, the same way every OTHER hand-written
// interpretation file under rust/src/kernel/ already is.
//
// GROUND TRUTH FOR THE MATCHING LOGIC ITSELF, read directly rather than
// guessed at: `Ports::Query::InMemory#holds?` (lib/hecks/ports/
// query/in_memory.rb) — the engine that actually answers a memory-backed
// aggregate's query in Ruby, and the same shape `QueryInterpreter#holds?`
// (lib/hecks/runtime/query_interpreter.rb) deliberately duplicates
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
// `NoneInState` is a NINTH remaining gap, of a different shape — its own
// enum variant, `parse`, and matching logic (`none_in_state_matches`,
// below) all exist and are proven correct, but `rust/project/queries.rb`
// still deliberately never generates a `none_in_state` condition (that
// file's own comment on `QUERY_COMPARATOR_VARIANTS` has the real reason:
// no generated call site can hand it the cross-domain search list it
// needs yet, so generating one today would silently answer every row
// `true` rather than a real anti-join).

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
    /// THE NINTH, LATE-ADDED comparator — `Vocabulary::QueryComparator`
    /// declared it long before this enum caught up (item #9, whole-
    /// project table-unification survey). A CROSS-AGGREGATE ANTI-JOIN,
    /// not a plain value comparison — `held`/`want` alone can never
    /// answer it, so it is deliberately NOT wired into `matches` below
    /// the way the other eight are; see `none_in_state_matches` and
    /// `repository.rs`'s `filter_entries_cross_domain`.
    NoneInState,
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
        QueryComparator::NoneInState,
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
            "none_in_state" => Some(QueryComparator::NoneInState),
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
            // `held`/`want` alone can never answer this — it needs a
            // REPOSITORY (possibly another domain's own), which this
            // total, side-channel-free function has no way to receive.
            // `repository.rs`'s `filter_entries_cross_domain` special-
            // cases `NoneInState` and calls `none_in_state_matches`
            // BEFORE ever reaching here — this arm exists only so the
            // match stays exhaustive, and its answer is the SAME safe
            // default `none_in_state_matches` itself falls back to with
            // no repository access (Ruby's own `return true unless
            // registry` — "not excluded" rather than a wrong answer or a
            // panic), for the one caller that could ever reach it: a
            // future direct `.matches()` call that bypasses the cross-
            // domain-aware path this comparator actually needs.
            QueryComparator::NoneInState => true,
        }
    }
}

/// `Comparison#none_in_state?` (lib/hecks/query_specification/
/// common/comparison.rb), ported directly — the ONE comparator this
/// kernel answers with real repository access rather than a pure `held`/
/// `want` comparison. `want` is `"Aggregate:state"` (already `comparable`
/// -reduced like every other comparator's own `want`, but this one's
/// value is always a plain string wire literal in practice — the where-
/// clause's own RHS, never a caller-bound arg); `held` is the referring
/// record's own foreign-key field, read the SAME `comparable`-reduced way
/// every other comparator's `held` already is.
///
/// `cross_domain` — `(domain name, that domain's own AggregateScan)`
/// pairs, searched in order, first match wins — mirrors Ruby's own
/// `find_aggregate_by_name`'s `registry.bluebooks.each` exactly (a bare
/// aggregate name is ambiguous across domains in principle; Ruby doesn't
/// refuse on the ambiguity, it picks the first, since a where-clause
/// never raises). An EMPTY slice — every real production caller today,
/// `filter_entries`'s own thin wrapper below — answers `true`
/// unconditionally, the same "not excluded" default Ruby's own `return
/// true unless registry` falls back to when nothing is threaded through:
/// no REAL deployed Lambda ever populates a second domain's own Store in
/// the same running process (rust/src/generated/mod.rs's own header —
/// `active` is a Cargo-feature choice of exactly one), so this default is
/// not a placeholder waiting to be wired up, it is the honest, permanent
/// answer for every real caller that exists today. The search-every-
/// domain MECHANISM itself is proven correct below (`#[cfg(test)]`)
/// against a synthetic multi-domain fixture, matching Ruby's own code
/// path — not against anything a real corpus or a real deployment
/// exercises, since nothing does.
pub fn none_in_state_matches(cross_domain: &[(&str, &dyn super::AggregateScan)], held: &Json, want: &Json) -> bool {
    let Some((aggregate_name, state)) = to_s(want).split_once(':').map(|(a, s)| (a.to_string(), s.to_string()))
    else {
        return true;
    };
    let held_id = to_s(held);

    for (domain_name, store) in cross_domain {
        let qualified = format!("{domain_name}::{aggregate_name}");
        let Some(entries) = store.scan(&qualified) else { continue };

        let Some((_, record)) = entries.iter().find(|(id, _)| *id == held_id) else { return true };
        let record_state = comparable(&record.dig("state").cloned().unwrap_or(Json::Null));
        return to_s(&record_state) != state;
    }

    // No domain in the search list declares this aggregate at all —
    // Ruby's own `find_aggregate_by_name` returns `nil` the same way,
    // and `none_in_state?` reads that the same as "not excluded".
    true
}

/// gt/gte/lt/lte are numeric-only and silently FALSE otherwise — ported
/// from `Ports::Query::InMemory.ordered?`/`QueryInterpreter#ordered?`
/// verbatim. A where-clause never raises the way a `given` does, so a
/// comparator asked to order a String (or a `nil`/`Json::Null`) just
/// answers "no match" for every record it's asked about, not a refusal —
/// this is the real, proven TYPE-MISMATCH behavior (that file's own
/// comment: "lt was already exactly this permissive"), not an assumption.
fn ordered(held: &Json, want: &Json) -> bool {
    matches!(held, Json::Num(_) | Json::Float(_)) && matches!(want, Json::Num(_) | Json::Float(_))
}

/// Only ever called once `ordered` has already gated the comparison —
/// the NaN fallback below is unreachable in practice, kept rather than
/// `unwrap`ing so this stays a total function like everything else in
/// this kernel, never a panic over a comparator this crate's own JSON
/// parser could never actually hand it (a non-`Num` `Json` value).
///
/// `pub(crate)` (not private) since `read_model.rs`'s own `median`
/// function reuses it for the identical "read this as a float for
/// comparison/averaging" purpose `gt`/`gte`/`lt`/`lte` already need it
/// for — the same `pub(crate)` treatment `to_s`, below, already got for
/// an analogous reuse (`nest`'s own JSON-object-key stringification).
pub(crate) fn as_f64(value: &Json) -> f64 {
    match value {
        Json::Num(n) | Json::Float(n) => *n,
        _ => f64::NAN,
    }
}

/// Ruby's own `#to_s` on a comparator's held/wanted SCALAR — only ever
/// called on a value `comparable` (below) has already reduced to a
/// scalar, except inside `members`, which maps it over an Array's own
/// elements (a `list_of` field's members, each comparable-reduced
/// individually first, the same as a bare scalar field already is).
pub(crate) fn to_s(value: &Json) -> String {
    match value {
        Json::Str(s) => s.clone(),
        Json::Num(n) if n.fract() == 0.0 && n.abs() < 1e15 => (*n as i64).to_string(),
        Json::Num(n) => n.to_string(),
        // Ruby's `Float#to_s` always shows a decimal point (`10.0.to_s`
        // => `"10.0"`) -- unlike Num, this never collapses to Integer
        // styling regardless of whether the value happens to be whole.
        Json::Float(n) => {
            let rendered = n.to_string();
            if rendered.contains('.') || rendered.contains('e') || rendered.contains('E') {
                rendered
            } else {
                format!("{rendered}.0")
            }
        }
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

    if let Some((_, numeric)) = fields.iter().find(|(_, v)| matches!(v, Json::Num(_) | Json::Float(_))) {
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

// Item #9, whole-project table-unification survey — `none_in_state_matches`
// had zero coverage of its own before this (the real corpus's one usage,
// spec/query_none_in_state_growth_spec.rb, exercises Ruby's OWN
// `none_in_state?` end to end, never this Rust port). Proven here against
// a hand-rolled multi-domain `AggregateScan` fixture — the SAME-DOMAIN
// cases mirror that Ruby spec's own scenario exactly (a `Claim` a
// `Board::Assignment` points at, "held" vs "released" vs never-filed); the
// CROSS-DOMAIN cases have no real corpus or deployment analog at all (this
// file's own header on `none_in_state_matches` has the full story) — they
// prove the search-every-domain MECHANISM matches Ruby's own
// `registry.bluebooks.each`/`find_aggregate_by_name`, first-match-wins
// included, not that any real caller exercises it. `#[cfg(test)]` only —
// compiled out of every real build.
#[cfg(test)]
mod none_in_state_tests {
    use super::{none_in_state_matches, Json};
    use crate::kernel::AggregateScan;

    /// A hand-rolled stand-in for a real generated `Store` — `domain`
    /// plus `(bare aggregate name, entries)` pairs, searched by the SAME
    /// domain-qualified name (`"Domain::Aggregate"`) a real `Store::scan`
    /// matches against. Real generated stores never coexist like this in
    /// one process (see this module's own header) — this fixture is what
    /// lets the search-every-domain mechanism be proven correct anyway.
    struct FakeStore {
        domain: &'static str,
        aggregates: Vec<(&'static str, Vec<(String, Json)>)>,
    }

    impl AggregateScan for FakeStore {
        fn scan(&self, aggregate: &str) -> Option<Vec<(String, Json)>> {
            let bare = aggregate.strip_prefix(&format!("{}::", self.domain))?;
            self.aggregates.iter().find(|(name, _)| *name == bare).map(|(_, entries)| entries.clone())
        }
    }

    /// One stored record whose own `state` attribute is a single-field
    /// value object — `ClaimState { value: "held" }`, matching the real
    /// corpus fixture's own shape exactly (`comparable` unwraps this the
    /// same way it unwraps any other single-field VO).
    fn record_in_state(state: &str) -> Json {
        Json::obj(vec![("state", Json::obj(vec![("value", Json::str(state))]))])
    }

    #[test]
    fn with_no_domains_to_search_answers_vacuously_true() {
        // Ruby's own `return true unless registry` — the default every
        // real production caller gets today (repository.rs's own
        // `filter_entries` passes an empty list).
        assert!(none_in_state_matches(&[], &Json::str("c1"), &Json::str("Claim:held")));
    }

    #[test]
    fn excludes_a_row_whose_target_is_currently_in_the_named_state() {
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("held"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(!none_in_state_matches(&stores, &Json::str("c1"), &Json::str("Claim:held")));
    }

    #[test]
    fn keeps_a_row_whose_target_has_moved_out_of_the_named_state() {
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![("Claim", vec![("c2".into(), record_in_state("released"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(none_in_state_matches(&stores, &Json::str("c2"), &Json::str("Claim:held")));
    }

    #[test]
    fn keeps_a_row_whose_target_was_never_filed_at_all() {
        // "no record in that state" reads the same as "a record, but not
        // in that state" — the real spec fixture's own "nonexistent"
        // case, ported.
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![("Claim", vec![])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(none_in_state_matches(&stores, &Json::str("nonexistent"), &Json::str("Claim:held")));
    }

    #[test]
    fn keeps_every_row_when_no_domain_declares_the_named_aggregate_at_all() {
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(none_in_state_matches(&stores, &Json::str("c1"), &Json::str("NoSuchAggregate:held")));
    }

    #[test]
    fn searches_a_second_domain_when_the_first_does_not_declare_the_aggregate() {
        // THE CROSS-DOMAIN CASE — no real corpus or deployment analog
        // (this file's own header), but Ruby's own `find_aggregate_by_
        // name` genuinely searches every loaded domain, so this proves
        // the Rust mechanism matches that exactly.
        let domain_a = FakeStore { domain: "DomainA", aggregates: vec![("Widget", vec![])] };
        let domain_b =
            FakeStore { domain: "DomainB", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("held"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("DomainA", &domain_a), ("DomainB", &domain_b)];
        assert!(!none_in_state_matches(&stores, &Json::str("c1"), &Json::str("Claim:held")));
    }

    #[test]
    fn first_match_wins_when_two_domains_declare_the_same_bare_aggregate_name() {
        // Mirrors Ruby's OWN documented ambiguity policy
        // (comparison.rb's `find_aggregate_by_name`: "ambiguity ...
        // picks the first match rather than refusing") — proving the
        // SEARCH ORDER itself, not merely that some match exists:
        // DomainA's own "c1" is "held" (excludes); DomainB's is
        // "released" (would keep) — if the search consulted DomainB
        // instead of stopping at DomainA, this would wrongly read `true`.
        let first = FakeStore { domain: "DomainA", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("held"))])] };
        let second =
            FakeStore { domain: "DomainB", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("released"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("DomainA", &first), ("DomainB", &second)];
        assert!(!none_in_state_matches(&stores, &Json::str("c1"), &Json::str("Claim:held")));
    }
}
