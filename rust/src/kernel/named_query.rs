// HAND-WRITTEN, ONCE, GENERIC — the same "compile shapes, interpret
// behavior" split this kernel already holds every OTHER reaction/mutation
// table to (`PolicyRule`/orchestrate.rs, `ProcessManagerDef`/orchestrate.rs):
// a declared bluebook `query "Name" do ... end` block compiles down to a
// static `QueryDef` row (`rust/project/queries.rb`'s own `query_conditions`,
// `rust/project/registry.rb`'s own `emit_query_table`), and `run` below is
// the ONE hand-written interpreter every generated domain's own `QUERIES`
// table is walked through — never bespoke per-query Rust control flow.
//
// SCOPE: exactly the subset `rust/project/queries.rb`'s own
// `query_skip_reason` admits — one or more field-comparator conditions,
// ANDed together, against a single aggregate's OWN attributes (no
// order_by/limit/cursor/consistency/freshness/authorization/null_semantics/
// inspection/index_hints; no where clause hopping through a reference; no
// literal comparator value whose true JSON type the exported IR can't
// recover). A declared query outside that subset simply has no row in the
// generated table at all — `kernel/cli.rs`'s own STRING-shaped "query" step
// refuses it the same clean way an unrouted command already does, never
// silently wrong.
//
// GROUND TRUTH: `Runtime::QueryInterpreter#interpret`
// (lib/hecksagain/runtime/query_interpreter.rb), read directly — for THIS
// subset specifically (no order_by/limit/hop), `interpret` and its own
// differential twin `reference_interpret` are PROVABLY the identical
// answer: both share the exact same `ordered` helper (with `order_by: nil`
// that's `Ports::Query::Ordering.apply`'s own identity-only sort, i.e. by
// id — the same order `repository::filter_entries`'s own id-ascending sort
// already produces), and a hop-free where clause makes `reference_where_
// holds?` fall straight through to `where_holds?` via its own early return
// (`return where_holds?(clause, record, args) unless step`) — never a
// second, separately-computed answer. `kernel/cli.rs`'s STRING-form
// dispatch leans on exactly this property to report `reference_rows` as a
// clone of `rows` rather than actually re-running a second walk.
use super::{query_comparators::QueryComparator, repository, AggregateScan, Json, Refusal};

/// ONE declared query, compiled. `verb` is the fully-qualified
/// "Domain::Aggregate.QueryName" `kernel/cli.rs`'s STRING-form "query" step
/// matches against; `aggregate` is the bare "Domain::Aggregate"
/// `AggregateScan::scan` expects — the SAME prefix the ad hoc OBJECT-form
/// filter step (`kernel/cli.rs`'s own `run_filter`) already resolves
/// through, so a query and an ad hoc filter against the same aggregate
/// always answer the SAME "unknown aggregate" refusal path.
#[derive(Debug, Clone, Copy)]
pub struct QueryDef {
    pub verb: &'static str,
    pub aggregate: &'static str,
    pub conditions: &'static [QueryCondition],
}

/// ONE where clause, compiled — `field`/`comparator` read exactly like the
/// ad hoc filter's own (query_comparators.rs); `value` is the one axis a
/// DECLARED query adds over that ad hoc shape.
#[derive(Debug, Clone, Copy)]
pub struct QueryCondition {
    pub field: &'static str,
    pub comparator: QueryComparator,
    pub value: QueryConditionValue,
}

#[derive(Debug, Clone, Copy)]
pub enum QueryConditionValue {
    /// A rendered wire STRING, baked in at codegen time.
    /// `rust/project/queries.rb`'s own `query_where_skip_reason` only ever
    /// lets a literal reach here when the target field is PROVABLY
    /// string-shaped (a plain `String`/lifecycle attribute, a bare
    /// `Reference<X>` id, or a value object that collapses to a single
    /// non-numeric member) or when the comparator is `in`/`contains` —
    /// both of which stringify their OWN argument unconditionally in Ruby
    /// too (`Ports::Query::InMemory#members`/`#contains?`, read directly),
    /// so a rendered-string literal is exactly as correct there as the
    /// ORIGINAL value would have been, whatever its real type. Never used
    /// for gt/gte/lt/lte — a literal's true numeric-vs-string identity is
    /// unrecoverable from the exported IR, so those queries simply have no
    /// row at all rather than a wrong or silently-approximated one.
    Literal(&'static str),
    /// A caller-bound Symbol — the declared query's OWN attribute name,
    /// read off THIS call's `args` object at dispatch time. Missing
    /// entirely reads as `Json::Null`, mirroring Ruby's own
    /// `resolve_query_value` (`args[value]` — a plain Hash miss, never a
    /// raise) exactly.
    Arg(&'static str),
}

/// THE GENERIC INTERPRETER — every condition ANDed together by chaining
/// `repository::filter_entries` (repository.rs's own header: "id-
/// ascending, ALWAYS" — chaining preserves that through every step, so the
/// final result stays sorted by id exactly like a single-condition filter
/// already is, matching `Runtime::QueryInterpreter#interpret`'s own
/// single-pass `wheres.all? { ... }` AND for this hop-free, order-free
/// subset). `store` is generic over `AggregateScan`, not any one domain's
/// own `Store` — matching `filter_entries`'s own design: nothing here is
/// domain-specific, only the `QueryDef` data a generated `QUERIES` table
/// hands it is.
pub fn run(store: &impl AggregateScan, def: &QueryDef, args: &Json) -> Result<Vec<(String, Json)>, Refusal> {
    let mut entries = store
        .scan(def.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", def.aggregate)))?;

    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        entries = repository::filter_entries(entries, condition.field, condition.comparator, &want);
    }

    Ok(entries)
}

/// The lookup `kernel/cli.rs`'s STRING-form "query" step dispatches
/// through — a linear scan over a generated domain's own `QUERIES` table
/// (small in every real corpus; no index structure earns its keep here).
pub fn find<'a>(table: &'a [QueryDef], verb: &str) -> Option<&'a QueryDef> {
    table.iter().find(|def| def.verb == verb)
}
