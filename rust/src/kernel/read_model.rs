// HAND-WRITTEN, ONCE, GENERIC — the same "compile shapes, interpret
// behavior" split this kernel already holds every OTHER reaction/mutation/
// query table to (`PolicyRule`/orchestrate.rs, `QueryDef`/named_query.rs):
// a declared bluebook `report "X" do ... end` block (`IR::ReadModel` — the
// `read_model` construct; `report` is the language's own word for it, per
// `language/bluebook/syntax.bluebook`'s `was: "read_model"`) compiles down
// to a static `ReadModelDef` row (`rust/project/read_models.rb`'s own
// `read_model_def`/`emit_read_model_table`), and `run` below is the ONE
// hand-written interpreter every generated domain's own `READ_MODELS`
// table is walked through — never bespoke per-read-model Rust control flow.
//
// SCOPE: exactly the subset `rust/project/read_models.rb`'s own
// `read_model_skip_reason` admits — a ROOT aggregate fetched by its own
// reference id, plus one or more OTHER aggregate heads found by scanning
// and matching a reference attribute back to an already-projected
// root/sibling row. No `where`/`order_by`/`limit`/`offset`/`cursor`/
// `consistency`/`freshness`/`authorize`(TenantScope)/`nulls`/
// `inspect_query`/`use_index` — see `read_models.rb`'s own header for the
// full argument, including why `where`/`order_by`/`limit` specifically are
// a STRUCTURAL gap in the canonical IR this generator reads, not merely an
// unported feature. A declared read model outside that subset simply has
// no row in the generated table at all — `kernel/cli.rs`'s own STRING-
// shaped "query" step refuses it the same clean way an unrouted verb or an
// unrecognized named query already does, never silently wrong.
//
// GROUND TRUTH: `Runtime::ReadModelInterpreter#project`
// (lib/hecksagain/runtime/read_model_interpreter.rb), read directly.
use super::{repository, AggregateScan, Json, Refusal};

/// ONE reference attribute on a NON-ROOT head's own aggregate — "this
/// aggregate carries a field named `field` that is `Reference<X>`, where
/// `target_aggregate` is `X`'s own bare `AggregateScan::scan` prefix
/// ("Domain::Aggregate")." Ground truth: `Runtime::ReadModelInterpreter#
/// reference_fields`, read directly — `aggregate.attributes.select {
/// attribute.reference? && attribute.type.target_name == target.to_s
/// }.map(&:name)` — baked in at codegen time
/// (`rust/project/read_models.rb`'s own `read_model_reference_fields`)
/// since this compiled kernel has no runtime attribute-type reflection the
/// way Ruby's own live `IR::Attribute` objects give the interpreter.
#[derive(Debug, Clone, Copy)]
pub struct ReferenceField {
    pub target_aggregate: &'static str,
    pub field: &'static str,
}

/// ONE declared `include` — a row of `IR::ReadModel#aggregate_heads`
/// (`{aggregate:, as:, many:}`), plus two facts precomputed at codegen
/// time rather than re-derived on every call: `is_root` (this head's own
/// `aggregate` equals the read model's declared `reference_to` target) and
/// `reference_fields` (see above — always empty for the root head, which
/// is never matched by reference at all; it's fetched directly by the
/// caller's own id argument).
#[derive(Debug, Clone, Copy)]
pub struct ReadModelHead {
    pub aggregate: &'static str,
    pub as_name: &'static str,
    pub many: bool,
    pub is_root: bool,
    pub reference_fields: &'static [ReferenceField],
}

/// ONE declared `report "X" do ... end` block, compiled — the read-model
/// analogue of `named_query::QueryDef`. `verb` is the "Domain.Name" wire
/// string `kernel::cli.rs`'s STRING-form "query" step matches a read-model
/// ask against — see that file's own header for how it tells this shape
/// apart from a named/declared AGGREGATE query's "Domain::Aggregate.Name"
/// shape (the presence of "::" before the first "."). `reference_name` is
/// the wire ARGUMENT key a caller's own `args` must carry the root id
/// under (`IR::ReadModel#reference_name`; Ruby's own `args.fetch(model.
/// reference_name)`). `heads` is in DECLARED order — `run`'s own header
/// explains why the computation below needs a DIFFERENT order than this
/// array's own.
#[derive(Debug, Clone, Copy)]
pub struct ReadModelDef {
    pub verb: &'static str,
    pub reference_name: &'static str,
    pub heads: &'static [ReadModelHead],
}

/// The lookup `kernel/cli.rs`'s STRING-form "query" step dispatches
/// through for a read-model ask (a bare "Domain.Name" string, no "::") —
/// a linear scan over a generated domain's own `READ_MODELS` table, the
/// same shape `named_query::find` already uses for the SIBLING "Domain::
/// Aggregate.Name" shape.
pub fn find<'a>(table: &'a [ReadModelDef], verb: &str) -> Option<&'a ReadModelDef> {
    table.iter().find(|def| def.verb == verb)
}

/// THE GENERIC INTERPRETER — `Runtime::ReadModelInterpreter#project`,
/// ported directly, for exactly the subset this module's own header
/// describes. Returns the SINGLE projected row (a JSON object, one entry
/// per declared head's own `as_name`) — never an array; `kernel/cli.rs`'s
/// own caller wraps it in a one-element `Json::Array`, matching Ruby's own
/// `[heads.transform_values { ... }]` return shape (an array of exactly
/// one hash — one root instance in, one grouped row out, always).
///
/// ROOT-FIRST COMPUTATION, DECLARED-ORDER OUTPUT — load-bearing, not a
/// style choice, and not this kernel's own invention: it is `Runtime::
/// ReadModelInterpreter#project`'s own documented correctness property
/// (a newer `read_model_interpreter.rb` than this branch otherwise
/// carries states it in so many words: "ROOT FIRST, ALWAYS — regardless
/// of `include` order in the bluebook... this loop used to run heads in
/// their literal declared order and match each 'many' head against
/// whatever was ALREADY in `projected` — empty, the very first time
/// through, if a many-side head happened to be declared before the root.
/// A real, live bug (not a guess)... silently returned an empty array...
/// no error, just a wrong, too-small answer"). Every non-root head is
/// matched against whichever OTHER heads are already computed at the
/// moment it's processed (`projected`, below) — so a many-side head
/// processed before its own root would always compare against an EMPTY
/// `projected` and come back wrong regardless of what this kernel does,
/// unless the root is guaranteed to go first. Partitioning `def.heads`
/// into root-first for COMPUTATION — while walking `def.heads` in its own
/// original array order for the OUTPUT below — closes that regardless of
/// what order a bluebook author happened to write `include`s in, mirroring
/// Ruby's own `root_heads, other_heads = model.aggregate_heads.partition
/// { ... }` / `(root_heads + other_heads).each` exactly. For every real
/// corpus read model this generator admits, the root already IS the first
/// `include` (so this reordering is a no-op in practice today) — but
/// computing it for real, rather than trusting declared order to always
/// happen to be right, is what makes THAT a fact about today's corpus, not
/// a silent assumption this interpreter depends on.
pub fn run(store: &impl AggregateScan, def: &ReadModelDef, args: &Json) -> Result<Json, Refusal> {
    let reference_id = args
        .get(def.reference_name)
        .and_then(Json::as_str)
        .ok_or_else(|| Refusal::TypeMismatch(format!("{}: missing reference argument {:?}", def.verb, def.reference_name)))?
        .to_string();

    let (root_heads, other_heads): (Vec<&ReadModelHead>, Vec<&ReadModelHead>) = def.heads.iter().partition(|head| head.is_root);

    // One entry per head ALREADY computed, in COMPUTATION order
    // (root-first) — exactly Ruby's own `projected`, read the same way:
    // every candidate record is checked against EVERY entry seen so far,
    // never just the immediately-preceding one.
    let mut projected: Vec<(&'static str, Vec<(String, Json)>)> = Vec::new();
    let mut rows_by_as: std::collections::HashMap<&'static str, (bool, Vec<(String, Json)>)> = std::collections::HashMap::new();

    for head in root_heads.into_iter().chain(other_heads) {
        let rows = if head.is_root {
            vec![fetch_root(store, head, &reference_id)?]
        } else {
            scan_matching(store, head, &projected)?
        };

        projected.push((head.aggregate, rows.clone()));
        rows_by_as.insert(head.as_name, (head.many, rows));
    }

    // DECLARED order, for the OUTPUT ONLY — `def.heads` itself, not the
    // root-first order `projected`/`rows_by_as` were just built in.
    //
    // `repository::row_json` wraps EVERY record here, at every level of
    // nesting — the root row AND every reference-matched sibling row —
    // matching Ruby's own `Value.materialize(row(record))`, where `row`
    // is plain `record.to_h` and a live Ruby aggregate record's `to_h`
    // already carries `id` alongside every other attribute. This
    // kernel's own generated `to_json()` does not (see `row_json`'s own
    // header in repository.rs), so it has to be added back explicitly
    // here — unlike a named query or an ad hoc filter, whose OWN row_json
    // wrapping only ever needs to happen once, at the single top-level
    // row `kernel/cli.rs` builds, a read model's own answer nests a
    // record at every head, so the wrapping has to happen at every head
    // too.
    let mut out = Vec::with_capacity(def.heads.len());
    for head in def.heads {
        let (many, rows) = rows_by_as
            .remove(head.as_name)
            .expect("every head in def.heads was computed in the loop above — as_name is unique per read model (ReadModelBuilder#add_aggregate_head)");
        let value = if many {
            Json::Array(rows.into_iter().map(|(id, record)| repository::row_json(id, record)).collect())
        } else {
            rows.into_iter().next().map(|(id, record)| repository::row_json(id, record)).unwrap_or(Json::Null)
        };
        out.push((head.as_name.to_string(), value));
    }

    Ok(Json::Object(out))
}

/// The root head's own single row — `ReadModelInterpreter#fetch`, ported
/// directly: find the one instance by id, `NotFound` if it isn't there.
/// Unlike every other head, the root is never scanned-and-matched; it's
/// looked up directly by the caller's own reference argument.
fn fetch_root(store: &impl AggregateScan, head: &ReadModelHead, reference_id: &str) -> Result<(String, Json), Refusal> {
    let entries = store
        .scan(head.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", head.aggregate)))?;

    entries
        .into_iter()
        .find(|(id, _)| id == reference_id)
        .ok_or_else(|| Refusal::NotFound(format!("no {} with id {reference_id:?}", head.aggregate)))
}

/// A NON-ROOT head's own rows — `ReadModelInterpreter#matching`, ported
/// directly: every instance of this head's own aggregate whose reference
/// field(s) point back at a row ALREADY in `projected`, sorted by id
/// ascending (Ruby's own `matching(records) { ... }.sort_by(&:id)`).
fn scan_matching(
    store: &impl AggregateScan,
    head: &ReadModelHead,
    projected: &[(&'static str, Vec<(String, Json)>)],
) -> Result<Vec<(String, Json)>, Refusal> {
    let entries = store
        .scan(head.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", head.aggregate)))?;

    let mut matched: Vec<(String, Json)> = entries.into_iter().filter(|(_, record)| record_matches(record, head, projected)).collect();
    matched.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(matched)
}

/// `projected.any? { |source| reference_fields(...).any? { |field|
/// source[:rows].any? { |parent| reference(record[field]) == parent.id }
/// } }`, ported directly — reorganized to iterate this HEAD's own
/// (precomputed) `reference_fields` on the outside and `projected` on the
/// inside, rather than Ruby's own outside-in order, which changes nothing
/// observable: both are a plain existential over the same "does some
/// (field, already-projected source) pair match" question, so which side
/// is the outer loop only affects short-circuit order, never the answer.
fn record_matches(record: &Json, head: &ReadModelHead, projected: &[(&'static str, Vec<(String, Json)>)]) -> bool {
    head.reference_fields.iter().any(|reference_field| {
        let Some(held_id) = record.get(reference_field.field).and_then(Json::as_str) else { return false };
        projected
            .iter()
            .any(|(aggregate, rows)| *aggregate == reference_field.target_aggregate && rows.iter().any(|(id, _)| id == held_id))
    })
}
