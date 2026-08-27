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
// root/sibling row, PLUS (as of 2026-08-11) a declared `where`/`order_by`/
// `limit` on the ONE eligible many-side head (`filtered_head`, below) —
// `IR::ReadModel#to_h` now spells these three on the wire (`read_models.rb`'s
// own header has the history: it didn't used to). Still no `offset`/
// `cursor`/`consistency`/`authorize`(TenantScope)/`nulls` beyond the
// default/`inspect_query` — real capabilities `Ports::Query::InMemory`/
// `TenantScope` implement that this generator still doesn't port, the SAME
// boundary `rust/project/queries.rb` already draws for a declared AGGREGATE
// query, applied consistently here (`read_models.rb`'s own header has the
// full argument). A declared read model outside that subset simply has no
// row in the generated table at all — `kernel/cli.rs`'s own STRING-shaped
// "query" step refuses it the same clean way an unrouted verb or an
// unrecognized named query already does, never silently wrong.
//
// GROUND TRUTH: `Runtime::ReadModelInterpreter#project`
// (lib/hecks/runtime/read_model_interpreter.rb) for the overall shape;
// `Ports::Query::InMemory.execute`/`Ports::Query::Ordering`/
// `QuerySpecification::Common::NullPolicy` (lib/hecks/ports/query/,
// lib/hecks/query_specification/common/null_policy.rb) for exactly
// what `apply_filtered_head_options` below ports — all read directly.
use super::{query_ordering, repository, AggregateScan, Json, QueryCondition, QueryConditionValue, Refusal};

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

/// A read model's own declared `order_by :field, :direction`, applying to
/// `ReadModelDef::filtered_head` alone — a plain alias, not a distinct
/// shape: this used to be its own hand-written struct (`queries.rb`'s own
/// header, at the time, said "declared-AGGREGATE-query codegen refuses
/// `order_by` outright, so there was nothing sort-shaped to reuse" — true
/// the day it was written), but the moment `named_query.rs` needed the
/// identical field/direction pair for a declared AGGREGATE query's own
/// `order_by` (2026-08-11), keeping two structurally-identical types
/// around would only invite the SAME drift `kernel/query_ordering.rs`'s
/// own extraction exists to prevent one level down, in the functions that
/// consume them. Ground truth: `QuerySpecification::Common::OrderBy`
/// (lib/hecks/query_specification/common/order_by.rb) — `field`/
/// `direction`, read directly; `query_ordering::OrderBy`'s own header has
/// the rest.
pub type ReadModelOrderBy = query_ordering::OrderBy;

/// A read model's own declared `limit N`, applying to `ReadModelDef::
/// filtered_head` alone — an alias for the same reason `ReadModelOrderBy`
/// just above is one now, not a distinct shape: `query_ordering::Limit`'s
/// own header has the full Literal/Arg argument (ground truth: `Ports::
/// Query::InMemory.execute`'s own `resolve(declared.limit.value,
/// args).to_i`, lib/hecks/ports/query/in_memory.rb).
pub type ReadModelLimit = query_ordering::Limit;

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
///
/// `filtered_head`/`conditions`/`order_by`/`limit` are the ONE eligible
/// many-side head's own where/order_by/limit — ground truth: `IR::
/// ReadModel#filtered_head_name` (lib/hecks/bluebook/ir/read_model.rb):
/// "ReadModelBuilder#seal_query_options already refuses ambiguity (zero or
/// several many-heads with options declared)... so any interpreter can ask
/// this directly rather than re-deriving or re-checking it" — this generator
/// trusts the same invariant, the same way `rust/project/read_models.rb`'s
/// own `read_model_filtered_head_as` does. `filtered_head` is `None`, and
/// `conditions` empty/`order_by`/`limit` both `None`, for a read model that
/// declares none of the three — the ordinary case, and the ONLY case before
/// 2026-08-11.
#[derive(Debug, Clone, Copy)]
pub struct ReadModelDef {
    pub verb: &'static str,
    pub reference_name: &'static str,
    pub heads: &'static [ReadModelHead],
    pub filtered_head: Option<&'static str>,
    pub conditions: &'static [QueryCondition],
    pub order_by: Option<ReadModelOrderBy>,
    pub limit: Option<ReadModelLimit>,
}

/// The lookup `kernel/cli.rs`'s STRING-form "query" step dispatches
/// through for a read-model ask (a bare "Domain.Name" string, no "::") —
/// a linear scan over a generated domain's own `READ_MODELS` table, the
/// same shape `named_query::find` already uses for the SIBLING "Domain::
/// Aggregate.Name" shape.
///
/// R2 FIX (docs/audits/2026-08-11-bug-triage.md) — `ReadModelDef::verb`
/// (`rust/project/read_models.rb`'s own `read_model_def`) only ever spells
/// the read model's DECLARED name ("Banking.CustomerPortfolio"), that
/// file's own header explaining why: the ONE spelling this generator ever
/// needs to emit. But `Runtime::Chapter#read_model` — the ground truth,
/// `lib/hecks/bluebook/behaviour/chapter.rb` — accepts EITHER that spelling
/// OR the snake-cased one (`ReadModel#query_name`, `Naming.snake(@name)`),
/// and a real corpus caller uses the snake_case spelling for exactly this
/// read model (`spec/corpus/banking.json`'s own "Banking.customer_portfolio"
/// query step). A `def.verb == verb` exact match alone made this compiled
/// artifact refuse a read model Ruby answers for real — not a genuine
/// codegen gap (`rust/src/generated/banking/manifest.json` already marks
/// `Banking::CustomerPortfolio` `"generated": true`), just a narrower
/// accepted-spelling set than Ruby's own. `matches_snake_alias` below
/// closes it without touching codegen at all: still one row, one spelling
/// baked in, checked against both of the two spellings Ruby itself accepts.
pub fn find<'a>(table: &'a [ReadModelDef], verb: &str) -> Option<&'a ReadModelDef> {
    table.iter().find(|def| def.verb == verb || matches_snake_alias(def.verb, verb))
}

/// `declared_verb` is `def.verb`, "Domain.Name" (the read model's own
/// declared, PascalCase-or-whatever-was-written name); `asked` is the wire
/// string a caller actually sent. True when they name the same domain and
/// `asked`'s own name half is `declared_verb`'s own name half run through
/// `to_snake` — the compiled-in port of `Hecks::Naming.snake`, below.
fn matches_snake_alias(declared_verb: &str, asked: &str) -> bool {
    let Some((domain, name)) = declared_verb.split_once('.') else { return false };
    let Some((asked_domain, asked_name)) = asked.split_once('.') else { return false };

    domain == asked_domain && to_snake(name) == asked_name
}

/// A direct port of `Hecks::Naming.snake` (lib/hecks/naming.rb):
///
/// ```ruby
/// text.to_s
///     .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
///     .gsub(/([a-z\d])([A-Z])/, '\1_\2')
///     .downcase
/// ```
///
/// Both `gsub`s only ever insert an underscore at a CASE BOUNDARY; neither
/// one's own match consumes more than the two characters straddling that
/// boundary (the first pass leaves the run-of-uppercase's own LAST letter
/// glued to the lowercase word that follows it, same as the second pass's
/// single preceding lowercase/digit character), so both collapse into one
/// single left-to-right scan of adjacent-character pairs here: no
/// dependency exists between one inserted `_` and the NEXT character pair's
/// own decision, in either the Ruby original or this port, so running the
/// two passes' conditions as one pass changes nothing observable. No regex
/// engine in this dependency-free kernel (`rust/Cargo.toml` carries no
/// crate at all) — every declared read-model/query name this needs to
/// snake-case is plain ASCII, so `is_ascii_*` suffices.
fn to_snake(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut out = String::with_capacity(name.len() + 4);

    for (i, &c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            // Rule 1 (`([A-Z]+)([A-Z][a-z])`): the boundary between the
            // last two letters of a >=2 run of uppercase, when the second
            // of those two is itself followed by a lowercase letter —
            // "HTTPServer" splits before the "S" of "Server", not before
            // the "H" of "HTTP".
            let rule1 = prev.is_ascii_uppercase() && c.is_ascii_uppercase() && chars.get(i + 1).is_some_and(char::is_ascii_lowercase);
            // Rule 2 (`([a-z\d])([A-Z])`): a plain lowercase-or-digit to
            // uppercase boundary — "customerPortfolio" splits before "P".
            let rule2 = (prev.is_ascii_lowercase() || prev.is_ascii_digit()) && c.is_ascii_uppercase();
            if rule1 || rule2 {
                out.push('_');
            }
        }
        out.push(c);
    }

    out.make_ascii_lowercase();
    out
}

#[cfg(test)]
mod snake_alias_tests {
    use super::*;

    // Ground truth: `Hecks::Naming.snake` — every case here was checked
    // against the real Ruby method, not merely against this port of it.
    #[test]
    fn to_snake_matches_ruby_naming_snake() {
        assert_eq!(to_snake("CustomerPortfolio"), "customer_portfolio");
        assert_eq!(to_snake("ComplianceDashboard"), "compliance_dashboard");
        assert_eq!(to_snake("Active"), "active");
        assert_eq!(to_snake("ByFee"), "by_fee");
        assert_eq!(to_snake("HTTPServer"), "http_server");
        assert_eq!(to_snake("Type2Foo"), "type2_foo");
    }

    #[test]
    fn find_accepts_both_the_declared_and_the_snake_cased_spelling() {
        let table = [ReadModelDef {
            verb: "Banking.CustomerPortfolio",
            reference_name: "reference",
            heads: &[],
            filtered_head: None,
            conditions: &[],
            order_by: None,
            limit: None,
        }];

        assert!(find(&table, "Banking.CustomerPortfolio").is_some());
        assert!(find(&table, "Banking.customer_portfolio").is_some());
        assert!(find(&table, "Banking.somethingelse").is_none());
        assert!(find(&table, "Other.customer_portfolio").is_none());
    }
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
        let mut rows = if head.is_root {
            vec![fetch_root(store, head, &reference_id)?]
        } else {
            scan_matching(store, head, &projected)?
        };

        // `Ports::Query::InMemory.execute(rows, model, args) if head[:as] ==
        // eligible`, ported directly — applied BEFORE this head's rows go
        // into `projected`, so any LATER head's own reference-matching sees
        // the FILTERED rows, exactly like Ruby's own `projected << { ...,
        // rows: rows }` (assigned to the post-`execute` `rows`, not the
        // pre-filter scan). The root is never `filtered_head` — options only
        // ever apply to a many-side head (`seal_query_options`) — so this
        // never fires before `reference_id` above has already resolved it.
        if def.filtered_head == Some(head.as_name) {
            rows = apply_filtered_head_options(rows, def, args);
        }

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

/// THE ELIGIBLE HEAD'S OWN where/order_by/limit — `Ports::Query::InMemory.
/// execute`, ported for exactly the subset `read_models.rb`'s own
/// eligibility gate admits (offset deliberately excluded — out of scope,
/// same as every OTHER option that generator still refuses). Where-
/// filtering reuses `repository::filter_entries` chained per condition —
/// exactly `named_query::run`'s own AND, never reimplemented. Order/limit
/// are `query_ordering::apply` (kernel/query_ordering.rs) — EXTRACTED from
/// this very function (2026-08-11), not reused from anywhere new: this
/// module's identity-sort/declared-order/limit tail used to live here
/// directly, until `named_query.rs` needed the identical logic for a
/// declared AGGREGATE query's own `order_by`/`limit` and duplicating it a
/// second time would have been exactly the drift this whole codebase's
/// "compile shapes, interpret behavior" split exists to avoid. See that
/// module's own header for the full ground-truth citation and the one
/// real structural difference between this caller and `named_query::run`
/// (a read model's `filtered_head` selection, which happens ABOVE this
/// function, in `run`, not inside it).
fn apply_filtered_head_options(mut rows: Vec<(String, Json)>, def: &ReadModelDef, args: &Json) -> Vec<(String, Json)> {
    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        rows = repository::filter_entries(rows, condition.field, condition.comparator, &want);
    }

    query_ordering::apply(rows, def.order_by.as_ref(), def.limit.as_ref(), args)
}
