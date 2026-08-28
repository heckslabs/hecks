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
// 2026-08-11) a declared `order_by`/`limit` on that same result set, PLUS
// (as of Phase 10, equivalence-gap plan) a declared `offset` on it too —
// still no cursor/consistency/freshness/authorization/null_semantics/
// inspection/index_hints; no where clause hopping through a
// reference; no literal comparator value whose true JSON type the
// exported IR can't recover; no order_by field that doesn't reduce to a
// plain JSON string or number. A declared query outside that subset
// simply has no row in the generated table at all — `kernel/cli.rs`'s own
// STRING-shaped "query" step refuses it the same clean way an unrouted
// command already does, never silently wrong.
//
// GROUND TRUTH: `Runtime::QueryInterpreter#interpret`
// (lib/hecks/runtime/query_interpreter.rb), read directly — for THIS
// subset specifically (no hop), `interpret` and its own differential twin
// `reference_interpret` are PROVABLY the identical answer, order_by/
// offset/limit included: both share the exact same `ordered`/`skipped`/
// `capped` sequence — `ordered = ordered(matched, declared.order_by,
// declared.null_semantics)`, then `skipped = declared.offset ? ordered.
// drop(resolve_query_value(declared.offset.value, args).to_i) : ordered`
// (OFFSET FIRST — SQL's own `LIMIT n OFFSET m` order, not the reverse),
// then `capped = declared.limit ? skipped.first(resolve_query_value(
// declared.limit.value, args).to_i) : skipped` — applied AFTER the where
// clauses (`matched`), which is the only place the two interpreters ever
// differ (`reference_where_holds?` vs plain `where_holds?`); a hop-free
// where clause makes `reference_where_holds?` fall straight through to
// `where_holds?` via its own early return (`return where_holds?(clause,
// record, args) unless step`), so order_by/offset/limit run on an
// IDENTICAL `matched` set either way, never a second, separately-computed
// answer.
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
use super::{query_comparators::QueryComparator, query_ordering, repository, AggregateScan, Json, Refusal, RefusalSite};

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
    /// `None` for the ordinary case (no declared `offset`, true for every
    /// declared query before this field existed). `query_ordering::apply`
    /// runs this BEFORE `limit` — see that function's own header for why.
    pub offset: Option<query_ordering::Offset>,
    pub limit: Option<query_ordering::Limit>,
    /// `None` for the ordinary case — no declared `authorize`, or one
    /// declared with no `tenant:` (`Runtime::TenantScope.apply`'s own
    /// `return declared unless tenant` — a REAL, harmless no-op in Ruby
    /// too, not merely unsupported). See `TenantAuth`'s own doc for what
    /// this actually does.
    pub authorization: Option<TenantAuth>,
}

/// `authorize policy, tenant: :field` — Phase 10 of the equivalence-gap
/// plan. Ground truth: `Runtime::TenantScope.apply` (lib/hecks/runtime/
/// tenant_scope.rb), read directly. That module's own header is explicit
/// about what this is and is not: "the boundary itself, made mandatory...
/// whether THIS caller actually holds `policy` for THIS tenant needs real
/// identity infrastructure this runtime does not have — that stays a
/// named, open gap." `policy` itself is never read by `TenantScope.apply`
/// at all (only `.tenant` is) — this generator matches that exactly,
/// carrying no `policy` field here either.
///
/// TWO EFFECTS, both ported: (1) `args.key?(tenant)` must hold or Ruby
/// raises `Unauthorized`/`tenant_required` — `run_cross_domain` below
/// checks this explicitly, since a QUIETLY missing arg would otherwise
/// resolve through `QueryConditionValue::Arg`'s own `unwrap_or(Json::
/// Null)` miss-is-null reading and just filter to an empty (or wrong)
/// result instead of refusing. (2) a synthetic `field == args[tenant]`
/// where-clause gets ANDed onto the query's own declared ones
/// (`Scoped#wheres = __getobj__.wheres + [@clause]`) — baked in at
/// CODEGEN TIME here instead (`rust/project/queries.rb`'s own
/// `query_conditions` appends it), since the compiled shape never
/// changes: always `Eq` against `QueryConditionValue::Arg(tenant_field)`.
/// `tenant_field` doing double duty as both the where-clause FIELD name
/// and the wire ARG key name is Ruby's own convention, not an accident —
/// `TenantScope.apply`'s `tenant = tenant.to_sym` is the one value both
/// checks and the synthetic clause all read.
#[derive(Debug, Clone, Copy)]
pub struct TenantAuth {
    /// The query's own bare declared name (`IR::Query#name` — "Rented,"
    /// never the qualified "SafeDepositBox.Rented" verb) — `{query}` in
    /// `RefusalSite::UnauthorizedTenantRequired`'s own template, matching
    /// `RefusalWording.render("Unauthorized", "tenant_required", query:
    /// declared.name, field: tenant)`'s exact placeholder value.
    pub query_name: &'static str,
    pub tenant_field: &'static str,
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
    /// A `gt`/`gte`/`lt`/`lte` (or a numeric-kind `eq`/`ne`) literal,
    /// baked in as a real `f64` at codegen time rather than wire text --
    /// `rust/project/queries.rb`'s `query_where_skip_reason` only lets
    /// one of these reach here when `query_field_kind` has already
    /// proven the target field numeric-shaped (Integer/Float, or a
    /// value object that collapses to one), so there's no string-vs-
    /// number ambiguity left to resolve here: the field being numeric
    /// is what makes it safe, not the literal text's own shape. Resolves
    /// to `Json::Num`, never `Json::Float` -- a query condition's own
    /// value is a comparison operand, never serialised back to a
    /// caller, so the Int-vs-Float wire distinction `Json::Float`
    /// exists to preserve doesn't apply here.
    NumericLiteral(f64),
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
    run_cross_domain(store, def, args, &[])
}

/// `run`'s own real implementation, with one addition: an explicit
/// `cross_domain` search list threaded straight through to `repository::
/// filter_entries_cross_domain` for any condition using `NoneInState`
/// (see that function's own header, and query_comparators.rs's). `run`
/// above passes an empty list, matching `filter_entries`'s own thin-
/// wrapper shape — every real declared `query "X" do ... end` a
/// generated `QUERIES` table carries dispatches through the plain,
/// unchanged `run` today; a `none_in_state` condition inside one answers
/// vacuously true (Ruby's own no-registry default) the same as any other
/// caller that hasn't threaded a cross-domain search list through.
pub fn run_cross_domain(
    store: &impl AggregateScan,
    def: &QueryDef,
    args: &Json,
    cross_domain: &[(&str, &dyn AggregateScan)],
) -> Result<Vec<(String, Json)>, Refusal> {
    if let Some(auth) = &def.authorization {
        if args.get(auth.tenant_field).is_none() {
            return Err(Refusal::Unauthorized(RefusalSite::UnauthorizedTenantRequired.render(&[
                ("query", auth.query_name),
                ("field", auth.tenant_field),
            ])));
        }
    }

    let mut entries = store
        .scan(def.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", def.aggregate)))?;

    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        entries =
            repository::filter_entries_cross_domain(entries, condition.field, condition.comparator, &want, cross_domain);
    }

    Ok(query_ordering::apply(entries, def.order_by.as_ref(), def.offset.as_ref(), def.limit.as_ref(), args))
}

/// The lookup `kernel/cli.rs`'s STRING-form "query" step dispatches
/// through — a linear scan over a generated domain's own `QUERIES` table
/// (small in every real corpus; no index structure earns its keep here).
pub fn find<'a>(table: &'a [QueryDef], verb: &str) -> Option<&'a QueryDef> {
    table.iter().find(|def| def.verb == verb)
}
