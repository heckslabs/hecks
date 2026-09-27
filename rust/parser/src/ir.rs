//! IR structs mirroring `lib/hecks/bluebook/ir/*.rb`'s `to_h`, in Ruby's key order.
//! Their JSON must byte-match `JSON.pretty_generate(Exporter.call(...))`.

/// A captured Ruby value, rendered through `Hecks::Literal` where Ruby does (see ruby_value.rs).
pub type Literal = Option<crate::ruby_value::Value>;

#[derive(Debug, Clone, Default)]
pub struct Attribute {
    pub name: String,
    pub type_name: String, // `Reference<Target>` spelling for a reference, else the bare type name
    pub list: bool,
    // The raw author value, passed through with no `Literal.render`.
    pub default: Option<crate::ruby_value::Value>,
    pub optional: bool,
    pub pattern: Option<String>,
    pub admits: Option<String>,
    // `has_many`, `has_one` or `belongs_to`, kept apart from `Reference<Target>` and `list`.
    pub relationship: Option<String>,
}

impl Attribute {
    /// The target of a `"Reference<Target>"`-spelled `type_name`, else `None`.
    pub fn reference_target(&self) -> Option<&str> {
        self.type_name
            .strip_prefix("Reference<")
            .and_then(|rest| rest.strip_suffix('>'))
    }
}

#[derive(Debug, Clone, Default)]
pub struct Given {
    pub description: Option<String>,
    pub canonical: String,
}

pub type Ensures = Given;
pub type Invariant = Given;

// `projects :name, from: :"reference.remote_field"` (ADR 0025); all three are plain identifiers.
#[derive(Debug, Clone, Default)]
pub struct ProjectedField {
    pub name: String,
    pub reference: String,
    pub remote_field: String,
}

// One state or several, stored as the plain captured value rather than a `Given`-shaped rule.
// `None` when the command has no `from:` guard.
#[derive(Debug, Clone, PartialEq)]
pub enum CommandFrom {
    Single(String),
    Multiple(Vec<String>),
}

// Argument sources emit `{kind: "argument", name}`; literal sources emit
// `{kind: "literal", value}` raw, not `Literal.render`-ed (only `append` fields are rendered).
#[derive(Debug, Clone)]
pub enum MutationSource {
    Argument(String),
    Literal(crate::ruby_value::Value),
    /// `state(:field)`: the record's own field, read from the pre-dispatch state.
    State(String),
}

#[derive(Debug, Clone)]
pub enum Mutation {
    Append {
        target: String,
        fields: Vec<(String, String)>,
    }, // field -> Literal::render spelling
    // Shares `Append`'s multi-binding `fields` shape with `op: "delegate"` and a dotted
    // "Entity.Command" target; its own variant keeps the emitter's match exhaustive.
    Delegate {
        target: String,
        fields: Vec<(String, String)>,
    },
    // `corrects "Event", ...`: same `fields` shape; `op` is "corrects", target is the event.
    Correction {
        target: String,
        fields: Vec<(String, String)>,
    },
    // `sign` mirrors `Vocabulary::MutationOp` ("1" increment, "-1" decrement, "" otherwise),
    // computed by `parse::command::mutation_sign` because the parser has no live table to read.
    Other {
        target: String,
        op: String,
        sign: String,
        source: Option<MutationSource>,
    },
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
    // The lifecycle state this command is admissible from; see `CommandFrom`.
    pub from: Option<CommandFrom>,
    // The raw captured `provenance from: { ... }` Hash, emitted without `Literal.render`.
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

/// `AuthorizationSpec#to_h`: both fields are bare `.to_s`, never Literal-rendered.
#[derive(Debug, Clone, Default)]
pub struct AuthorizationSpec {
    pub policy: String,
    pub tenant: Option<String>,
}

/// Mirrors `extra_options_to_h`. A typed struct, not a `BTreeMap`, because Ruby's declared
/// field order must be preserved. Shared by `Query` and `ReadModel`.
#[derive(Debug, Clone, Default)]
pub struct QueryOptions {
    pub offset: Option<OffsetSpec>,
    // Already-rendered text; cursor never gets ADR 0055's `on:` (out of scope — see this
    // struct's own callers).
    pub cursor: Option<String>,
    pub authorization: Option<AuthorizationSpec>,
    // `None` both when never declared and when `:native`; Ruby drops the default mode key.
    pub null_semantics: Option<String>,
    pub inspection: Option<String>,
}

/// ADR 0055's `on:` — which many-side `include`d aggregate (by TYPE, demodulised, not by its
/// `as:` alias) this clause/option applies to. `None` for an untargeted where/order_by/limit/
/// offset (Query context, or a ReadModel with a single many-side head); real only in ReadModel
/// context, where a `report` with several many-side heads needs it to say which one.
#[derive(Debug, Clone, Default)]
pub struct WhereClause {
    pub field: String,
    pub op: String,
    pub value: String, // Literal::render spelling
    pub target: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct OrderBy {
    pub field: String,
    pub direction: String,
    pub target: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct LimitSpec {
    pub value: String, // Literal::render spelling
    pub target: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct OffsetSpec {
    pub value: String, // Literal::render spelling
    pub target: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Entity {
    pub name: String,
    pub description: Option<String>,
    pub identified_by: Vec<String>,
    pub attributes: Vec<Attribute>,
    pub commands: Vec<Command>,
    pub queries: Vec<Query>,
    // A piece nested inside a piece, like an Aggregate's own `entities`.
    pub entities: Vec<Entity>,
    // A precondition shared across this piece's commands; declaration-only, like `Aggregate`.
    pub preconditions: Vec<Given>,
    // A shape rule checked against every instance of this piece.
    pub invariants: Vec<Invariant>,
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
    // Checked after every command, before save.
    pub invariants: Vec<Invariant>,
    // Named `given`s shared across commands. Declaration-only: Rust never resolves a command's
    // block-less `given("...")` against them (see `parse::command`).
    pub preconditions: Vec<Given>,
    // `projects :name, from: :"reference.remote_field"`. Kept out of `attributes` because
    // `EraGuard::ShapeDiff` walks only `attributes` to detect missing data.
    pub projected_fields: Vec<ProjectedField>,
    pub lifecycle: Option<Lifecycle>,
    pub entities: Vec<Entity>,
    pub queries: Vec<Query>,
    pub ports: Vec<DomainPort>,
    // Same raw-captured-Hash shape as `Command.provenance`.
    pub provenance: Literal,
}

#[derive(Debug, Clone, Default)]
pub struct ValueObject {
    pub name: String,
    pub attributes: Vec<Attribute>,
    pub invariants: Vec<Invariant>,
    pub closed_set: bool,
    // Ordered (field, typed-value) pairs, typed so numbers and bools keep their JSON type.
    pub members: Vec<Vec<(String, crate::ruby_value::Value)>>,
}

/// A read model's aggregate head row (`{aggregate:, as:, many:}`); `many` is a real JSON boolean.
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
    // `wheres`/`order_by`/`limit` are spelled explicitly, as in `IR::Query#to_h`.
    pub wheres: Vec<WhereClause>,
    pub order_by: Option<OrderBy>,
    pub limit: Option<LimitSpec>,
    pub aggregate_heads: Vec<AggregateHead>,
    // One `{"field": ...}` row per name, re-wrapped by `read_model_json`.
    pub group_by: Vec<String>,
    // `group_by`'s siblings; both are omitted from the wire when absent, not `null`.
    pub count: bool,
    pub median_field: Option<String>,
    // Same shape as `Query.options`.
    pub options: QueryOptions,
}

#[derive(Debug, Clone, Default)]
pub struct Policy {
    pub name: String,
    pub on_event: Option<String>,
    pub trigger_command: Option<String>,
    pub target_domain: Option<String>,
    // `across "X", expect_undelivered: true`; emitted as a boolean, `false` when not declared.
    pub expect_undelivered: bool,
    // `where`/`for_each` (`PolicyBuilder`); named `where_clause`/`for_each_query` because `where`
    // is reserved. `policy_json` still emits the keys `where`/`for_each` and derives `where_ast`.
    pub where_clause: Option<String>,
    pub for_each_query: Option<String>,
    // `trigger ... with:` bindings as `(key, Literal::render)` pairs; a Symbol keeps its colon.
    pub with_spec: Vec<(String, String)>,
}

#[derive(Debug, Clone, Default)]
pub struct DispatchSpec {
    pub command_name: String,
    pub with_spec: Vec<(String, String)>, // Literal::render spelling per value
    // A shape-identical `DispatchSpec` naming the command that undoes this dispatch. Field order
    // (`command_name`, `with_spec`, `compensates`) is the wire order `dispatch_spec_json` emits.
    // One level only: a compensation is not itself compensable.
    pub compensates: Option<Box<DispatchSpec>>,
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
    /// The receiving aggregate as routing metadata (`to: Payment`), not an attribute.
    pub to: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct DomainPort {
    pub name: String,
    pub operations: Vec<PortOperation>,
}

/// `IR::Bluebook#to_h`: the top of the construct chain, emitted as `ir.json`.
#[derive(Debug, Clone)]
pub struct Bluebook {
    pub ir_version: u32, // IR::Bluebook::IR_VERSION, pinned at 1 as of Stage 0
    pub name: String,
    pub version: Option<String>,
    pub vision: Option<String>,
    pub classification: Option<String>,
    // `formerly_known_as "OldName"`: always `None` today because `parse/chapter.rs` refuses it,
    // but the key is emitted on every chapter.
    pub formerly_known_as: Option<String>,
    pub aggregates: Vec<Aggregate>,
    pub read_models: Vec<ReadModel>,
    pub policies: Vec<Policy>,
    pub process_managers: Vec<ProcessManager>,
    // Core contexts this chapter attaches to (`attaches_to "Query", "ReadModel"`).
    pub attaches_to: Vec<String>,
    // `provides "authorization", grant: "..."`: one row per key, in source order.
    pub provides: Vec<Provision>,
}

impl Default for Bluebook {
    fn default() -> Self {
        Self {
            ir_version: 1,
            name: String::new(),
            version: None,
            vision: None,
            classification: None,
            formerly_known_as: None,
            aggregates: Vec::new(),
            read_models: Vec::new(),
            policies: Vec::new(),
            process_managers: Vec::new(),
            attaches_to: Vec::new(),
            provides: Vec::new(),
        }
    }
}

/// One row of a declared capability, emitted as `{"capability", "key", "verb"}`.
#[derive(Debug, Clone, Default)]
pub struct Provision {
    pub capability: String,
    pub key: String,
    pub verb: String,
}
