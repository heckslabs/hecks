//! Domain IR — the intermediate representation
//!
//! Same structure as the Ruby BluebookModel, but in Rust.
//! This is what the parser produces and the generators consume.
//!
//! [antibody-exempt: ir.rs — kernel-surface IR struct; the parser_shape
//!  specializer cannot be bootstrapped until the IR it reads also defines
//!  itself. Additions tracked here:
//!  • i106 dsl-mutation-primitives — Multiply / Clamp / Decay on MutationOp
//!    (enables pulse_organs.bluebook + consolidate.bluebook retirement)
//!  • identified-by-natural-keys — Aggregate.identified_by; subsumes
//!    unique:true singleton pattern; drives natural-key dispatch in
//!    repository.rs. Each addition enables a new .bluebook surface.]

use std::fmt;

#[derive(Debug, Clone)]
pub struct Domain {
    pub name: String,
    pub category: Option<String>,
    pub vision: Option<String>,
    pub aggregates: Vec<Aggregate>,
    pub policies: Vec<Policy>,
    pub fixtures: Vec<Fixture>,
    /// Optional top-level `entrypoint "CommandName"` — the command that
    /// `hecks-life run <file>` dispatches when invoked as an executable.
    /// None for library-style bluebooks with no default command.
    pub entrypoint: Option<String>,
    /// Capability bluebooks (e.g. status, statusline) declare an ordered
    /// list of `section "Title" do row "label", :field … end` blocks at
    /// the top level. The status runner walks these to render its
    /// dashboard rather than hard-coding section composition in Rust.
    /// Empty for bluebooks that don't declare any.
    pub sections: Vec<Section>,
}

/// One named section in a capability dashboard. Title becomes the bordered
/// header; rows are an ordered (label, field) list pointing at attributes
/// on the capability's stamped aggregate (e.g. `StatusReport`).
#[derive(Debug, Clone)]
pub struct Section {
    pub title: String,
    pub rows: Vec<SectionRow>,
}

/// One row inside a section. `label` is what the renderer prints on the
/// left; `field` is the attribute name on the capability's stamped
/// aggregate (snake_case). The renderer looks the field up at render
/// time and prints "—" when the attribute is missing.
#[derive(Debug, Clone)]
pub struct SectionRow {
    pub label: String,
    pub field: String,
}

#[derive(Debug, Clone)]
pub struct Aggregate {
    pub name: String,
    pub description: Option<String>,
    /// Bounded context = the bluebook namespace this aggregate was
    /// declared inside. `Hecks.bluebook "Library"` containing
    /// `aggregate "Inbox"` makes `context = Some("Library")`. Dispatch
    /// addresses an aggregate as `Context.Aggregate.Command` (i142) ;
    /// the same aggregate name in two contexts is two distinct
    /// aggregates, not a collision. Cross-corpus collisions like
    /// Identity (boot/being/first_breath) and Memory
    /// (miette/mind/library) resolve naturally once dispatch carries
    /// the context. Optional during the migration : aggregates from
    /// older code paths or bare-string parsers can still resolve
    /// without a context (legacy `Aggregate.Command` form), but new
    /// code is expected to set it. Closes i134 (context maps), i137
    /// (corpus-wide name collisions), i140 (Identity collision).
    pub context: Option<String>,
    /// Natural primary key — name of the attribute that identifies the
    /// aggregate. When set, dispatch routes by `attrs[identified_by]`
    /// (e.g. `inbox.Item identified_by :ref` → key = the dispatched ref
    /// value). When `None`, the repository mints a fresh u64 id.
    /// Subsumes the old `unique: true` adapter flag — a singleton is
    /// just an aggregate identified by an attribute with one canonical
    /// value, no special case.
    pub identified_by: Option<String>,
    pub attributes: Vec<Attribute>,
    pub commands: Vec<Command>,
    pub queries: Vec<Query>,
    pub value_objects: Vec<ValueObject>,
    /// Non-root entities owned by this aggregate. They have identity
    /// within the aggregate (some natural key field) and can mutate
    /// over their lifecycle, but are reached only through the root —
    /// other aggregates `reference_to` the root, never directly to
    /// the entity. Lifecycle bounded by the parent : when the
    /// aggregate's record is deleted the entities go with it.
    /// Distinct from `value_objects` (no identity, immutable, replaced
    /// wholesale) and from a separate `Aggregate` (queryable by id
    /// from outside, lifecycle independent).
    pub entities: Vec<Entity>,
    pub references: Vec<Reference>,
    pub lifecycle: Option<Lifecycle>,
}

#[derive(Debug, Clone)]
pub struct Attribute {
    pub name: String,
    pub attr_type: String,
    pub default: Option<String>,
    pub list: bool,
}

#[derive(Debug, Clone)]
pub struct Command {
    pub name: String,
    pub description: Option<String>,
    pub role: Option<String>,
    pub attributes: Vec<Attribute>,
    pub references: Vec<Reference>,
    pub emits: Option<String>,
    pub givens: Vec<Given>,
    pub mutations: Vec<Mutation>,
}

#[derive(Debug, Clone)]
pub struct Query {
    pub name: String,
    pub description: Option<String>,
    /// Query input parameters. When the DSL declares `attribute :author,
    /// String` inside a query block, that attribute becomes a kwarg the
    /// caller supplies at dispatch time. Where-clauses can reference
    /// these attributes by their symbol form (`:author`) and the runtime
    /// resolves the kwarg to a literal at filter time. (i101)
    pub attributes: Vec<Attribute>,
    /// Filter clauses applied in sequence by the runtime executor.
    /// `where(field: value)` parses to a WhereClause where `value` is
    /// either a literal (`"available"`) or a kwarg-ref (`":author"`)
    /// resolved against the query's input attributes at dispatch
    /// time. Multiple wheres compose as logical AND. (i101)
    pub wheres: Vec<WhereClause>,
    /// Optional sort spec. `order_by :title` parses to ascending on the
    /// named field ; `order_by :title, :desc` flips direction. The
    /// runtime sorts after where-filtering, before limit truncation. (i101)
    pub order_by: Option<OrderBy>,
    /// Optional record cap. `limit 10` truncates to ten records ;
    /// `limit :max_results` reads the value from the query's input
    /// kwargs at dispatch time. Same literal-or-kwarg pattern as
    /// where-clause values. (i101)
    pub limit: Option<LimitSpec>,
}

#[derive(Debug, Clone)]
pub struct Given {
    pub expression: String,
    pub message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Mutation {
    pub field: String,
    pub operation: MutationOp,
    pub value: String,
}

#[derive(Debug, Clone)]
pub enum MutationOp {
    Set,
    Append,
    Increment,
    Decrement,
    Toggle,
    /// Record-level deletion — `then_delete` (no field, no value). When
    /// applied, marks the aggregate state for removal so the dispatcher
    /// calls `Repository::delete` instead of `Repository::save`. The
    /// `field` and `value` slots on `Mutation` are empty strings ; the
    /// op type alone carries the intent. Used by retire-style commands
    /// (e.g. Antibody.RetireExemption) that close out a record after
    /// emitting their event.
    Delete,
    /// Multiplicative scaling — `then_set :strength, multiply: 0.95`.
    /// The `value` field on `Mutation` carries the source-text factor;
    /// the runtime parses it as f64. Float-typed result is stored as a
    /// numeric Str the way `increment_float` does, preserving parity
    /// with the existing fractional path.
    Multiply,
    /// Bound a numeric field to a closed interval — `then_set :strength,
    /// clamp: [0.0, 1.0]`. The `value` field carries the source-text
    /// list literal `[min, max]`. Used by per-tick body math (synapse
    /// strength, focus weight) where overshoot is normal and the shell
    /// previously did the awk-side clamp.
    Clamp,
    /// Exponential decay — `then_set :strength, decay: 0.05`. New value
    /// is `current * (1.0 - rate)`. Convenience over `multiply: 0.95`
    /// when expressing the loss rate is more legible than the survival
    /// rate. Both compose: a typical pulse-organs decay step is decay
    /// THEN clamp.
    Decay,
}

#[derive(Debug, Clone)]
pub struct ValueObject {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
}

#[derive(Debug, Clone)]
pub struct Entity {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    /// Commands declared inside the `entity "Foo" do … end` block.
    /// Dispatch addresses them as `Aggregate.Entity.Command` (3-part)
    /// or `Aggregate.Command` when the bare name is unique among the
    /// parent aggregate's entities (i111-J — close the DDD gap).
    /// Empty for entities declared with attributes only — backward
    /// compatible with pre-i111-J bluebooks.
    pub commands: Vec<Command>,
    /// Queries declared inside the entity block. Same dispatch
    /// address shape as commands : `Aggregate.Entity.Query`.
    pub queries: Vec<Query>,
    /// Optional lifecycle owned by this entity. Independent of the
    /// parent aggregate's lifecycle ; both can coexist (parent gates
    /// at root level, entity gates within its sub-record).
    pub lifecycle: Option<Lifecycle>,
    /// Natural primary key for this entity within the parent boundary.
    /// When None, the entity inherits the parent aggregate's identity
    /// for dispatch purposes (one entity instance per parent record).
    pub identified_by: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Reference {
    pub name: String,
    pub target: String,
    pub domain: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Lifecycle {
    pub field: String,
    pub default: String,
    pub transitions: Vec<Transition>,
}

#[derive(Debug, Clone)]
pub struct Transition {
    pub command: String,
    pub to_state: String,
    pub from_state: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Fixture {
    /// Optional logical identifier (set by the block form's first positional
    /// arg). None for inline-form fixtures.
    pub name: Option<String>,
    pub aggregate_name: String,
    pub attributes: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub struct WhereClause {
    pub field: String,
    pub op: WhereOp,
    pub value: String,
}

/// Filter operator for a WhereClause. Eq / Ne are the canonical pair
/// (handles `where(field: value)` and `where(field: { ne: value })`) ;
/// Gt / Gte / Lt / Lte cover ordered comparisons against numeric or
/// string fields. The runtime parses the value side as a literal or
/// kwarg-ref and applies the op to each candidate record. (i101)
#[derive(Debug, Clone)]
pub enum WhereOp {
    Eq,
    Ne,
    Gt,
    Gte,
    Lt,
    Lte,
}

#[derive(Debug, Clone)]
pub struct OrderBy {
    pub field: String,
    pub direction: Direction,
}

/// Sort direction for an OrderBy clause. Asc is the default when the
/// DSL declares `order_by :field` ; Desc is selected explicitly via
/// `order_by :field, :desc`. (i101)
#[derive(Debug, Clone)]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Debug, Clone)]
pub struct LimitSpec {
    pub value: String,
}

impl fmt::Display for Domain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{}", self.name)?;
        let agg_count = self.aggregates.len();
        for (ai, agg) in self.aggregates.iter().enumerate() {
            let is_last_agg = ai == agg_count - 1;
            let prefix = if is_last_agg { "└──" } else { "├──" };
            let cont = if is_last_agg { "    " } else { "│   " };
            writeln!(f, "{} {} — {}", prefix, agg.name, agg.description.as_deref().unwrap_or(""))?;
            let cmd_count = agg.commands.len();
            for (ci, cmd) in agg.commands.iter().enumerate() {
                let cmd_prefix = if ci == cmd_count - 1 { "└──" } else { "├──" };
                write!(f, "{}{} {}", cont, cmd_prefix, cmd.name)?;
                if let Some(ref emits) = cmd.emits {
                    write!(f, " -> {}", emits)?;
                }
                writeln!(f)?;
            }
        }
        if !self.policies.is_empty() {
            for pol in &self.policies {
                writeln!(f, "  {} : {} -> {}", pol.name, pol.on_event, pol.trigger_command)?;
            }
        }
        Ok(())
    }
}
