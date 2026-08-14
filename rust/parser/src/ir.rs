//! IR structs matching `lib/hecksagain/bluebook/ir/*.rb`'s own `to_h`
//! field-for-field, in Ruby's own key order — the target shape Stage 2+'s
//! real construction (parse/*.rs + build/*.rs) will populate and emit.rs
//! will serialize to byte-match `JSON.pretty_generate(Exporter.call(...))`.
//!
//! STAGE 1 HONESTY NOTE: nothing in this crate constructs one of these yet
//! (parse/*.rs handlers all stub out before reaching IR construction), so
//! these fields are read from the Ruby source's own `to_h` methods but are
//! UNVERIFIED by any differential test — spec/parser_parity_spec.rb's own
//! PENDING_MEMBERS table says so explicitly. Confirmed against the actual
//! Ruby source at Stage-1 time: Bluebook, Aggregate, Attribute, Command,
//! Mutation, Entity, Query, ValueObject, ReadModel, Policy, ProcessManager,
//! ProcessManagerHandler, DispatchSpec, Lifecycle. Re-verify field order
//! against Ruby's own `to_h` again at Stage 2, when this first has to
//! byte-match a real golden.

/// A `nil`-or-value Ruby field, rendered through `Hecksagain::Literal`
/// where the Ruby side does so (member/where/mutation source values) — see
/// ruby_value.rs. Plain JSON-shaped fields (strings, bools, numbers, lists)
/// don't need this and use native Rust types directly.
pub type Literal = Option<crate::ruby_value::Value>;

#[derive(Debug, Clone, Default)]
pub struct Attribute {
    pub name: String,
    pub type_name: String, // `Reference<Target>` spelling for a reference, else the bare type name
    pub list: bool,
    // `IR::Attribute#to_h`'s `default:` is the RAW Ruby value the author
    // wrote (`default: 0`, `default: { cents: 0 }`), passed straight
    // through with no `Literal.render` — the same "just re-`.generate` the
    // real value" shape `Mutation`'s own non-append literal source uses
    // (see `MutationSource::Literal`'s own comment). Not exercised by
    // pizzas.bluebook (no attribute there declares a default), kept
    // correct anyway since it's the same one Value type every other
    // captured-literal field already needs.
    pub default: Option<crate::ruby_value::Value>,
    pub optional: bool,
    pub pattern: Option<String>,
    pub admits: Option<String>,
}

impl Attribute {
    /// The target name out of a `"Reference<Target>"`-spelled `type_name`
    /// (`ir::Reference#to_s`'s own pinned spelling) — `None` for anything
    /// else. Used by `PortOperationBuilder#identity_attribute`'s own
    /// mirror: "does this operation carry an attribute referencing its
    /// owner".
    pub fn reference_target(&self) -> Option<&str> {
        self.type_name.strip_prefix("Reference<").and_then(|rest| rest.strip_suffix('>'))
    }
}

#[derive(Debug, Clone, Default)]
pub struct Given {
    pub description: Option<String>,
    pub canonical: String,
}

pub type Ensures = Given;
pub type Invariant = Given;

// `IR::Mutation#classified_source` (lib/hecksagain/bluebook/ir/command.rb)
// — an ARGUMENT-sourced mutation renders `{kind: "argument", name: ...}`;
// a LITERAL-sourced one renders `{kind: "literal", value: source}` with
// `source` passed straight through, NOT through `Literal.render` — a real,
// confirmed distinction found by reading `spec/golden/ir/Pizzas.json`
// directly: `Purchase`'s `then_set :status, to: "sold"` renders
// `"value": "sold"` (a bare JSON string), never `"value": "\"sold\""` the
// way a WHERE clause's own `Literal.render`-spelled value would. Only
// `Mutation#appended_fields` (the APPEND op's own `fields:` map) goes
// through `Literal.render` — kept as a String there for exactly that
// reason.
#[derive(Debug, Clone)]
pub enum MutationSource {
    Argument(String),
    Literal(crate::ruby_value::Value),
}

#[derive(Debug, Clone)]
pub enum Mutation {
    Append { target: String, fields: Vec<(String, String)> }, // field -> Literal::render spelling
    Other { target: String, op: String, source: Option<MutationSource> },
}

#[derive(Debug, Clone, Default)]
pub struct Command {
    pub name: String,
    pub role: Option<String>,
    pub goal: Option<String>,
    pub references: Option<String>,
    pub attributes: Vec<Attribute>,
    pub givens: Vec<Given>,
    pub ensures: Vec<Ensures>,
    pub mutations: Vec<Mutation>,
    pub emits: Vec<String>,
    // `CommandBuilder#provenance` — the RAW captured Hash (`provenance
    // from: { ... }`), same "Origin, not runtime identity" shape
    // `AggregateBuilder#provenance` carries one level up. NOT run through
    // `Literal.render` — `IR::Command#to_h`'s own `provenance: provenance`
    // embeds the raw Ruby Hash straight into `JSON.generate`, so this is
    // `Literal` (the same captured-value type `Attribute#default` already
    // uses), not a String. Not exercised by any real corpus command yet
    // (only Account, an AGGREGATE, declares one in banking.bluebook) —
    // kept correct anyway, the same "right even if unreachable today"
    // basis `emit.rs`'s own entity/process-manager renderers already used
    // before Stage 4 exercised them for real.
    pub provenance: Literal,
}

#[derive(Debug, Clone, Default)]
pub struct StateTransitionRow {
    pub command: String,
    pub to_state: String,
    pub from_state: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Lifecycle {
    pub field: String,
    pub default: String,
    pub transitions: Vec<StateTransitionRow>,
}

#[derive(Debug, Clone, Default)]
pub struct Query {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub wheres: Vec<WhereClause>,
    pub order_by: Option<OrderBy>,
    pub limit: Option<LimitSpec>,
    pub options: QueryOptions,
}

/// `ConsistencySpec#to_h` (`lib/hecksagain/query_specification/common/consistency_spec.rb`)
/// — `mode` bare (`mode.to_s`, no colon), `timeout` Literal-rendered
/// (`QuerySpecification.render_value`, only present when given).
#[derive(Debug, Clone, Default)]
pub struct ConsistencySpec {
    pub mode: String,
    pub timeout: Option<String>,
}

/// `FreshnessSpec#to_h` — same shape as `ConsistencySpec`, `max_age` in
/// place of `timeout`.
#[derive(Debug, Clone, Default)]
pub struct FreshnessSpec {
    pub mode: String,
    pub max_age: Option<String>,
}

/// `AuthorizationSpec#to_h` — BOTH fields bare `.to_s` (never
/// Literal-rendered): `policy` a Symbol's bare name, `tenant` likewise
/// when given.
#[derive(Debug, Clone, Default)]
pub struct AuthorizationSpec {
    pub policy: String,
    pub tenant: Option<String>,
}

/// `IndexHint#to_h` — `{name: name.to_s}`.
#[derive(Debug, Clone, Default)]
pub struct IndexHint {
    pub name: String,
}

/// Mirrors `QuerySpecification::Common::Options#extra_options_to_h`
/// FIELD FOR FIELD, in Ruby's own declared order (`options_to_h`:
/// offset, cursor, consistency, freshness, authorization, null_semantics,
/// inspection, index_hints) — a TYPED struct rather than the Stage-1
/// `BTreeMap<String, String>` this replaces, because a `BTreeMap` iterates
/// its keys ALPHABETICALLY, which silently disagrees with Ruby's own
/// declared field order the moment two options land on the SAME query
/// (confirmed real: `SafeDepositBox.Rented`'s own `authorize`+
/// `consistency` — alphabetically "authorization" sorts before
/// "consistency", but Ruby's own `options_to_h` writes `consistency`
/// FIRST). Shared verbatim by `Query` and `ReadModel` — both `< Options`
/// on the Ruby side, and `extra_options_to_h` excludes `wheres`/
/// `order_by`/`limit` by name in both, which is why those three stay
/// separate fields on each IR struct instead of living here too.
#[derive(Debug, Clone, Default)]
pub struct QueryOptions {
    // OffsetSpec/CursorSpec-shaped ({value: Literal-rendered}) — already
    // fully rendered text by the time it lands here, same convention
    // `LimitSpec.value` already uses.
    pub offset: Option<String>,
    pub cursor: Option<String>,
    pub consistency: Option<ConsistencySpec>,
    pub freshness: Option<FreshnessSpec>,
    pub authorization: Option<AuthorizationSpec>,
    // `NullSemantics#to_h`'s `mode.to_s` — `extra_options_to_h` drops this
    // key entirely when it's the default (`{mode: "native"}`), so this is
    // `None` both when `nulls` was never declared AND when it was
    // declared as `:native` — the caller never needs to tell those two
    // apart, matching Ruby's own `.reject` there exactly.
    pub null_semantics: Option<String>,
    // `InspectionSpec#to_h`'s `mode.to_s`.
    pub inspection: Option<String>,
    pub index_hints: Vec<IndexHint>,
}

#[derive(Debug, Clone, Default)]
pub struct WhereClause {
    pub field: String,
    pub op: String,
    pub value: String, // Literal::render spelling
}

#[derive(Debug, Clone, Default)]
pub struct OrderBy {
    pub field: String,
    pub direction: String,
}

#[derive(Debug, Clone, Default)]
pub struct LimitSpec {
    pub value: String, // Literal::render spelling
}

#[derive(Debug, Clone, Default)]
pub struct Entity {
    pub name: String,
    pub description: Option<String>,
    pub identified_by: Vec<String>,
    pub attributes: Vec<Attribute>,
    pub commands: Vec<Command>,
    pub queries: Vec<Query>,
    pub lifecycle: Option<Lifecycle>,
}

#[derive(Debug, Clone, Default)]
pub struct Aggregate {
    pub name: String,
    pub description: Option<String>,
    pub identified_by: Vec<String>,
    pub attributes: Vec<Attribute>,
    pub value_objects: Vec<ValueObject>,
    pub commands: Vec<Command>,
    pub lifecycle: Option<Lifecycle>,
    pub entities: Vec<Entity>,
    pub queries: Vec<Query>,
    pub ports: Vec<DomainPort>,
    // See `Command.provenance`'s own comment — same raw-captured-Hash
    // shape, one level up (`AggregateBuilder#provenance`). Real for
    // banking.bluebook's own `Account` (`provenance from: { source:
    // "HecksCanonical", source_id: "aggregate:account", source_version:
    // "1.0" }`) — the FIRST real corpus member to declare one.
    pub provenance: Literal,
}

#[derive(Debug, Clone, Default)]
pub struct ValueObject {
    pub name: String,
    pub attributes: Vec<Attribute>,
    pub invariants: Vec<Invariant>,
    pub closed_set: bool,
    pub members: Vec<Vec<(String, String)>>, // each member: ordered (field, text-value) pairs
}

/// `ReadModelBuilder#add_aggregate_head`'s own row shape
/// (`{aggregate:, as:, many:}`, Ruby Hash insertion order) — `many` is a
/// real Boolean on the wire (`IR::ReadModel#to_h`'s own `head.merge(as:
/// head[:as].to_s)` re-stringifies only `as`, never `many`), so this is a
/// typed struct rather than the generic `BTreeMap<String, String>` an
/// all-string open map would need to fake a bare JSON `true`/`false`
/// through.
#[derive(Debug, Clone)]
pub struct AggregateHead {
    pub aggregate: String,
    pub as_name: String,
    pub many: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ReadModel {
    pub name: String,
    pub description: Option<String>,
    pub reference_name: Option<String>,
    pub reference_target: Option<String>,
    pub query_name: String,
    // `IR::ReadModel#to_h` spells `wheres`/`order_by`/`limit` explicitly,
    // the SAME mechanism `IR::Query#to_h` uses (2026-08-11's read-model
    // where/order_by/limit task, `read_model.rb`'s own comment) — real for
    // `ComplianceDashboard` (banking.bluebook's own filtered, ordered,
    // capped read model), the first real corpus member to declare any.
    pub wheres: Vec<WhereClause>,
    pub order_by: Option<OrderBy>,
    pub limit: Option<LimitSpec>,
    pub aggregate_heads: Vec<AggregateHead>,
    // `ReadModelBuilder#group_by`'s own `{field: field.to_sym}` rows have
    // exactly one key — a bare `Vec<String>` of field names carries the
    // same information with no loss, and `read_model_json` re-wraps each
    // one into its own `{"field": ...}` object at emit time.
    pub group_by: Vec<String>,
    // See `Query.options`'s own header — the identical
    // `extra_options_to_h` shape, shared verbatim rather than a second
    // `BTreeMap`-ordering hazard copied one struct over.
    pub options: QueryOptions,
}

#[derive(Debug, Clone, Default)]
pub struct Policy {
    pub name: String,
    pub on_event: Option<String>,
    pub trigger_command: Option<String>,
    pub target_domain: Option<String>,
    // `where`/`for_each` — new language surface (conditional policy
    // dispatch + fan-out; `PolicyBuilder#where`/`#for_each`,
    // `lib/hecksagain/bluebook/dsl/policy_builder.rb`). Named
    // `where_clause`/`for_each_query` in Rust (`where` is a reserved
    // word, and `for_each` collides with nothing but is renamed to match)
    // — `emit.rs::policy_json` still spells the JSON keys `where`/
    // `for_each`, which is the only shape that has to match Ruby's own
    // wire format. `parse::policy::parse_body` does not build either yet
    // (Stage 1 "not yet implemented", same as every other pair
    // `spec/parser_coverage_spec.rb::PENDING_PAIRS` names) — both fields
    // stay `None`/`null` for every real corpus member this parser
    // already parses, which is what keeps `spec/parser_parity_spec.rb`'s
    // byte-exact comparisons passing for `pizzas`/`banking`/`reflex`/
    // etc. without building real `where`/`for_each` parsing.
    pub where_clause: Option<String>,
    pub for_each_query: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct DispatchSpec {
    pub command_name: String,
    pub with_spec: Vec<(String, String)>, // Literal::render spelling per value
}

#[derive(Debug, Clone, Default)]
pub struct ProcessManagerHandler {
    pub event_type: String,
    pub from_state: String,
    pub to_state: String,
    pub dispatches: Vec<DispatchSpec>,
}

#[derive(Debug, Clone, Default)]
pub struct ProcessManager {
    pub name: String,
    pub correlates_by: String,
    pub starts_on: Option<String>,
    pub ends_on: Option<String>,
    pub states: Vec<String>,
    pub handlers: Vec<ProcessManagerHandler>,
}

#[derive(Debug, Clone, Default)]
pub struct PortOperation {
    pub name: String,
    pub attributes: Vec<Attribute>,
    pub emits: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct DomainPort {
    pub name: String,
    pub operations: Vec<PortOperation>,
}

/// `IR::Bluebook#to_h` — the top of the construct chain, and the shape
/// `hecks-parse chapter` ultimately has to emit as `ir.json`.
#[derive(Debug, Clone)]
pub struct Bluebook {
    pub ir_version: u32, // IR::Bluebook::IR_VERSION, pinned at 1 as of Stage 0
    pub name: String,
    pub version: Option<String>,
    pub vision: Option<String>,
    pub classification: Option<String>,
    pub aggregates: Vec<Aggregate>,
    pub read_models: Vec<ReadModel>,
    pub policies: Vec<Policy>,
    pub process_managers: Vec<ProcessManager>,
    // canonical_form: Expression::CanonicalForm.table — the two
    // normalisation rules canonical.rs already hand-mirrors; Stage 2's
    // emit.rs writes this the same way for every chapter, not per-domain
    // data, so it isn't threaded through this struct.
}

impl Default for Bluebook {
    fn default() -> Self {
        Self {
            ir_version: 1,
            name: String::new(),
            version: None,
            vision: None,
            classification: None,
            aggregates: Vec::new(),
            read_models: Vec::new(),
            policies: Vec::new(),
            process_managers: Vec::new(),
        }
    }
}
