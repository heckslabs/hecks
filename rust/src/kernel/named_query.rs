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
// ANDed together, against a single aggregate's OWN attributes, PLUS (as of
// 2026-08-11) a declared `order_by`/`limit` on that same result set —
// still no cursor/consistency/freshness/authorization/null_semantics/
// inspection/index_hints/offset; no where clause hopping through a
// reference; no literal comparator value whose true JSON type the
// exported IR can't recover; no order_by field that doesn't reduce to a
// plain JSON string or number. A declared query outside that subset
// simply has no row in the generated table at all — `kernel/cli.rs`'s own
// STRING-shaped "query" step refuses it the same clean way an unrouted
// command already does, never silently wrong.
//
// GROUND TRUTH: `Runtime::QueryInterpreter#interpret`
// (lib/hecksagain/runtime/query_interpreter.rb), read directly — for THIS
// subset specifically (no hop), `interpret` and its own differential twin
// `reference_interpret` are PROVABLY the identical answer, order_by/limit
// included: both share the exact same `ordered`/`capped` sequence —
// `ordered = ordered(matched, declared.order_by, declared.null_semantics)`
// then `capped = declared.limit ? ordered.first(resolve_query_value(
// declared.limit.value, args).to_i) : ordered` — applied AFTER the where
// clauses (`matched`), which is the only place the two interpreters ever
// differ (`reference_where_holds?` vs plain `where_holds?`); a hop-free
// where clause makes `reference_where_holds?` fall straight through to
// `where_holds?` via its own early return (`return where_holds?(clause,
// record, args) unless step`), so order_by/limit run on an IDENTICAL
// `matched` set either way, never a second, separately-computed answer.
// `kernel/cli.rs`'s STRING-form dispatch leans on exactly this property
// to report `reference_rows` as a clone of `rows` rather than actually
// re-running a second walk.
//
// order_by/limit ARE NOT hand-written here a second time — `query_ordering
// ::apply` (kernel/query_ordering.rs) is the SAME identity-sort/declared-
// order/limit tail `read_model::run` already calls for a read model's own
// eligible head; that module's own header has the full argument for why a
// declared query needing this was simple reuse rather than new invention
// once it existed, and the one real structural difference between the two
// callers (a read model choosing among several aggregate heads; a query
// ordering/capping its own single result set directly, with no head
// selection at all).
use super::{query_comparators::QueryComparator, query_ordering, repository, AggregateScan, Json, Refusal};

/// ONE declared query, compiled. `verb` is the fully-qualified
/// "Domain::Aggregate.QueryName" `kernel/cli.rs`'s STRING-form "query" step
/// matches against; `aggregate` is the bare "Domain::Aggregate"
/// `AggregateScan::scan` expects — the SAME prefix the ad hoc OBJECT-form
/// filter step (`kernel/cli.rs`'s own `run_filter`) already resolves
/// through, so a query and an ad hoc filter against the same aggregate
/// always answer the SAME "unknown aggregate" refusal path.
/// `order_by`/`limit` are `None` for a query that declares neither — the
/// ordinary case, and the ONLY case before 2026-08-11. Both reuse
/// `query_ordering::OrderBy`/`Limit` directly (no `named_query`-local
/// wrapper type the way `read_model::ReadModelOrderBy`/`ReadModelLimit`
/// briefly were before THEY became aliases for the same reason) — this is
/// a brand-new consumer of that shared shape, so there was never a
/// pre-existing local type here to migrate away from.
#[derive(Debug, Clone, Copy)]
pub struct QueryDef {
    pub verb: &'static str,
    pub aggregate: &'static str,
    pub conditions: &'static [QueryCondition],
    pub order_by: Option<query_ordering::OrderBy>,
    pub limit: Option<query_ordering::Limit>,
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
/// single-pass `wheres.all? { ... }` AND for this hop-free subset), THEN
/// `query_ordering::apply` for the declared `order_by`/`limit` — Ruby's
/// own `ordered`/`capped` sequence, run AFTER `matched` the identical way
/// `interpret` itself orders: this module's own header has the full
/// ground-truth citation for why that sequencing (filter first, order/cap
/// second) is provably right, not just a plausible guess at Ruby's order
/// of operations. `store` is generic over `AggregateScan`, not any one
/// domain's own `Store` — matching `filter_entries`'s own design: nothing
/// here is domain-specific, only the `QueryDef` data a generated `QUERIES`
/// table hands it is.
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

    Ok(query_ordering::apply(entries, def.order_by.as_ref(), def.limit.as_ref(), args))
}

/// The lookup `kernel/cli.rs`'s STRING-form "query" step dispatches
/// through — a linear scan over a generated domain's own `QUERIES` table
/// (small in every real corpus; no index structure earns its keep here).
pub fn find<'a>(table: &'a [QueryDef], verb: &str) -> Option<&'a QueryDef> {
    table.iter().find(|def| def.verb == verb)
}
