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

use std::collections::BTreeMap;

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
    pub provenance: Option<String>,
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
    // extra_options_to_h — offset/cursor/consistency/freshness/authorization/
    // null_semantics/inspection/index_hints — an open map, kept unstructured
    // for Stage 1 since nothing builds a Query yet.
    pub extra_options: BTreeMap<String, String>,
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
    pub provenance: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ValueObject {
    pub name: String,
    pub attributes: Vec<Attribute>,
    pub invariants: Vec<Invariant>,
    pub closed_set: bool,
    pub members: Vec<Vec<(String, String)>>, // each member: ordered (field, text-value) pairs
}

#[derive(Debug, Clone, Default)]
pub struct ReadModel {
    pub name: String,
    pub description: Option<String>,
    pub reference_name: Option<String>,
    pub reference_target: Option<String>,
    pub query_name: String,
    pub aggregate_heads: Vec<BTreeMap<String, String>>,
    pub group_by: Vec<BTreeMap<String, String>>,
    pub extra_options: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Default)]
pub struct Policy {
    pub name: String,
    pub on_event: Option<String>,
    pub trigger_command: Option<String>,
    pub target_domain: Option<String>,
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
