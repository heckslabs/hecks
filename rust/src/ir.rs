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
    /// `storehouse run <file>` dispatches when invoked as an executable.
    /// None for library-style bluebooks with no default command.
    pub entrypoint: Option<String>,
    /// Capability bluebooks (e.g. status, statusline) declare an ordered
    /// list of `section "Title" do row "label", :field … end` blocks at
    /// the top level. The status runner walks these to render its
    /// dashboard rather than hard-coding section composition in Rust.
    /// Empty for bluebooks that don't declare any.
    pub sections: Vec<Section>,
    /// Process managers — event-driven state machines that coordinate
    /// multi-step business processes across aggregates. Phase 3 of the
    /// dream-study plan ships parser + IR ; runtime instantiation is
    /// Ruby-side. The Rust IR captures only the static shape (name,
    /// correlates_by, starts/ends event types, declared states, and
    /// per-event handlers with their from→to transition). The handler
    /// action body is intentionally NOT captured — that's Ruby code.
    pub process_managers: Vec<ProcessManager>,
    /// Cadences — declarative scheduled dispatch. Replaces imperative
    /// while-true-sleep-1-dispatch loops in shells (e.g. mindstream.sh)
    /// with a static IR : interval (e.g. "1s") + ordered list of
    /// `Aggregate.Command` dispatches with literal kwargs. Empty for
    /// bluebooks that declare no cadences.
    pub cadences: Vec<Cadence>,
    /// Block grammars — declarative keyword routing for the parser
    /// itself (i218). Each entry declares an ordered list of
    /// (keyword, parser_name) pairs. The parser walks a registry built
    /// from this IR rather than a hardcoded if-chain. Empty for
    /// bluebooks that don't declare grammar surface.
    pub block_grammars: Vec<BlockGrammar>,
}

/// One declared cadence. Mirrors
/// `Hecks::BluebookModel::Behavior::Cadence`. Static shape only — the
/// runtime tick loop is Ruby-side and not part of the parity contract.
#[derive(Debug, Clone)]
pub struct Cadence {
    pub name: String,
    pub interval: String,
    pub dispatches: Vec<CadenceDispatch>,
}

/// One scheduled dispatch within a cadence. `command_name` is the
/// qualified `Aggregate.Command` ; `attrs` carries literal kwargs as
/// ordered (key, source-text-value) pairs so the canonical JSON shape
/// is unambiguous and round-trips byte-identically with the Ruby dumper.
#[derive(Debug, Clone)]
pub struct CadenceDispatch {
    pub command_name: String,
    pub attrs: Vec<(String, String)>,
}

/// One declared block grammar (i218). Mirrors
/// `Hecks::BluebookModel::Behavior::BlockGrammar`.
///
/// `blocks` is an ordered Vec of `(keyword, parser_kind)` pairs ; the
/// parser walks them in declaration order, claiming a line for the
/// first keyword whose prefix matches. Authors can shadow a parent
/// keyword by listing a more-specific keyword first.
#[derive(Debug, Clone)]
pub struct BlockGrammar {
    pub name: String,
    pub blocks: Vec<BlockGrammarEntry>,
}

/// One keyword -> parser binding within a block grammar. `parser` is
/// the typed enum variant (not a function pointer) so each parser's
/// distinct return type stays in the type system.
#[derive(Debug, Clone)]
pub struct BlockGrammarEntry {
    pub keyword: String,
    pub parser: BlockParser,
}

/// Enum-keyed dispatch for the block_grammar registry (i218).
///
/// Each variant names one block parser kind. The parser's main loop
/// matches on this enum and calls the right typed `parse_*` function ;
/// adding a new keyword = one variant + one match arm + one row in the
/// canonical bluebook grammar.
///
/// Why an enum (not function pointers) : each parse function returns a
/// different IR struct (Aggregate / Policy / Cadence / ...). A function
/// pointer table would need either `Box<dyn Any>` returns or one giant
/// unified return enum ; matching on the kind and pushing into the
/// right Domain Vec is cleaner and zero-cost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockParser {
    Aggregate,
    Policy,
    ProcessManager,
    Cadence,
    Section,
    Fixture,
}

impl BlockParser {
    /// Resolve a parser-name string (as declared in the bluebook
    /// grammar) to a typed BlockParser variant. None when the name is
    /// unknown — the bluebook grammar can't reach functions that
    /// haven't been linked into the binary.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "parse_aggregate" => Some(Self::Aggregate),
            "parse_policy" => Some(Self::Policy),
            "parse_process_manager" => Some(Self::ProcessManager),
            "parse_cadence" => Some(Self::Cadence),
            "parse_section" => Some(Self::Section),
            "parse_fixture" => Some(Self::Fixture),
            _ => None,
        }
    }

    /// Stable string name (round-trips through `from_name`). Used by
    /// dump.rs / canonical_ir.rb so the parity contract carries the
    /// declared parser identity rather than a Rust-only enum tag.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Aggregate => "parse_aggregate",
            Self::Policy => "parse_policy",
            Self::ProcessManager => "parse_process_manager",
            Self::Cadence => "parse_cadence",
            Self::Section => "parse_section",
            Self::Fixture => "parse_fixture",
        }
    }
}

impl BlockGrammar {
    /// The canonical Bluebook grammar — used by `parser::parse` until
    /// a domain explicitly declares one via `block_grammar "Bluebook"
    /// do ... end`. Mirrors `bluebook/grammars/bluebook.grammar`
    /// declaration order. The specializer can regenerate this function
    /// from the .grammar bluebook ; it lives in code today as the
    /// kernel-floor bootstrap (the parser of bluebook can't itself
    /// require a parsed bluebook to run).
    pub fn canonical_bluebook() -> Self {
        Self {
            name: "Bluebook".into(),
            blocks: vec![
                entry("aggregate", BlockParser::Aggregate),
                entry("section", BlockParser::Section),
                entry("policy", BlockParser::Policy),
                entry("process_manager", BlockParser::ProcessManager),
                entry("cadence", BlockParser::Cadence),
                entry("fixture", BlockParser::Fixture),
            ],
        }
    }
}

fn entry(keyword: &str, parser: BlockParser) -> BlockGrammarEntry {
    BlockGrammarEntry { keyword: keyword.into(), parser }
}

/// One declared process_manager. Mirrors
/// `Hecks::BluebookModel::Behavior::ProcessManager` minus the action proc
/// (which is Ruby-side execution and not part of the static shape).
/// Parity contract : this struct round-trips byte-identically through
/// canonical_ir.rb / dump.rs.
#[derive(Debug, Clone)]
pub struct ProcessManager {
    pub name: String,
    pub correlates_by: String,
    pub starts_on: String,
    pub ends_on: Option<String>,
    pub states: Vec<String>,
    pub handlers: Vec<ProcessManagerHandler>,
}

/// One on-event handler within a process manager. The transition is
/// always single-entry (validated Ruby-side) ; we surface from→to as
/// two named fields rather than a one-key map so the canonical JSON
/// shape is unambiguous.
///
/// `dispatches` carries the structured list of declarative dispatches
/// declared via the `dispatch "Cmd", with: { ... }` keyword inside
/// `on/transition do ... end` blocks. Empty when the handler used the
/// Ruby-proc form (action body opaque to Rust). Phase 2.b
/// (pm-dispatch-enrichment) lifts bare-string dispatches into
/// `DispatchSpec` carrying per-call attribute flow.
///
/// `set_specs` carries the structured list of `set :attr, value_spec`
/// directives declared inside the on-block. Phase 2.c
/// (pm-attribute-writes) — writes flow into the PM instance's
/// per-instance attributes hash, where future `from_pm(:attr)` reads
/// resolve them. Empty `set_specs` means the handler doesn't write any
/// PM attributes (the most common case ; equivalent to all prior
/// handlers).
#[derive(Debug, Clone)]
pub struct ProcessManagerHandler {
    pub event_type: String,
    pub from_state: String,
    pub to_state: String,
    pub dispatches: Vec<DispatchSpec>,
    pub set_specs: Vec<(String, ValueSpec)>,
}

/// One declarative `dispatch "Cmd", with: { ... }` entry. The
/// `with_spec` is an ordered list of `(attr_name, ValueSpec)` pairs ;
/// declaration order is preserved (canonical IR uses an ordered
/// list of pairs, not an unordered map). Empty `with_spec` means the
/// dispatch fires bare (runtime auto-injects upstream refs).
///
/// i221-A — `for_each` promotes a single dispatch to a sweep. When
/// `Some`, the runtime reads the named query at dispatch time and
/// fires the receiving command once per returned record ;
/// `from_iter(:field)` in the with-spec resolves against the current
/// iteration record. `None` is the back-compat default for every
/// existing dispatch.
#[derive(Debug, Clone)]
pub struct DispatchSpec {
    pub command_name: String,
    pub with_spec: Vec<(String, ValueSpec)>,
    pub for_each: Option<ForEachSpec>,
}

/// Sweep source on a `DispatchSpec` (i221-A). Splits the qualified
/// `"Aggregate.query_name"` literal declared via `for_each: { from:
/// "..." }` into the structured halves. The runtime reads
/// `Aggregate.query_name()` at dispatch time and re-fires the
/// receiving command once per returned record.
///
/// Two qualified forms accepted :
///   "Aggregate.query_name"            — 2-part (back-compat) ;
///                                       `source_context` is `None`
///   "Context.Aggregate.query_name"    — 3-part, disambiguates when
///                                       multiple bluebooks declare
///                                       the same aggregate name (i142
///                                       Context.Aggregate.Command
///                                       resolution applied to query
///                                       lookups too)
#[derive(Debug, Clone)]
pub struct ForEachSpec {
    pub source_context: Option<String>,
    pub source_aggregate: String,
    pub query_name: String,
    /// i221-C (where-fan-out) — inputs threaded into the swept query so
    /// it filters by the triggering event. `where: { worker: from_event
    /// (:worker) }` on the `for_each:` hash ; each ValueSpec resolves
    /// against the event at sweep time -> query attrs -> the input-bound
    /// `where worker: :worker` filters. Empty = parameterless sweep (the
    /// i221-A back-compat default).
    pub query_inputs: Vec<(String, ValueSpec)>,
}

/// Sentinel describing how a single `with:` attribute resolves at
/// dispatch time. Mirrors the Ruby
/// `Behavior::ProcessManager::ValueSpec` shape exactly so canonical
/// IR is byte-equal across both halves.
///
/// - `Literal` — pass `value` through unchanged.
/// - `FromEvent` — read `event.data[name]` ; fall back to `default`.
/// - `FromPm` — read `pm_instance.data[name]` ; fall back to `default`.
/// - `FromIter` — i221-A — read `iter_record.data[field]` during a
///   `for_each:` sweep dispatch.
///
/// `default` is `None` when omitted in the DSL ; runtime treats a
/// `None` default as "leave the key unset on the dispatched command's
/// input" (the receiving aggregate will see no key, exactly as if the
/// dispatch never named it).
#[derive(Debug, Clone)]
pub enum ValueSpec {
    Literal { value: String },
    FromEvent { name: String, default: Option<String> },
    FromPm { name: String, default: Option<String> },
    FromIter { field: String },
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
    /// Bluebook category — the directory grouping under
    /// `aggregates/`, e.g. "discipline", "framework", "world". Stamped
    /// from the bluebook's `category "X"` declaration at parse time
    /// and preserved through `load_combined_domain` so the FQN
    /// resolver can match `Domain::Aggregate.Command` against either
    /// the bluebook context or its category. None when the bluebook
    /// didn't declare a category. Added 2026-05-12 for the i560 FQN
    /// migration (v2 — 2-segments-plus-dot form).
    pub category: Option<String>,
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
    /// f4 — aggregate-level invariants. Each is a predicate the runtime
    /// evaluates on the RESULTING state after EVERY command's mutations,
    /// before save. A `given` is checked on one command ; an invariant is
    /// checked on all of them. When any invariant's predicate is false the
    /// command is rejected (InvariantViolation, 0 events) — the same way a
    /// failed `given` rejects. Empty for aggregates that declare none.
    pub invariants: Vec<Invariant>,
    /// i254 — views per role. Each `View` declares a named projection
    /// of this aggregate's fields ; portals consume views by name
    /// (`record.view("for_customer")`) so role-scoped renderers all
    /// pull from the same single source of truth. Empty when no
    /// `view "name" do ... end` blocks were declared.
    pub views: Vec<View>,
}

#[derive(Debug, Clone)]
pub struct Attribute {
    pub name: String,
    pub attr_type: String,
    pub default: Option<String>,
    pub list: bool,
    pub required: bool,
}

#[derive(Debug, Clone)]
pub struct Command {
    pub name: String,
    pub description: Option<String>,
    pub role: Option<String>,
    pub attributes: Vec<Attribute>,
    pub references: Vec<Reference>,
    pub emits: Option<String>,
    pub emits_identified_by: Option<String>,
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
    /// Multiplicity range. Defaults to Cardinality { min: 0, max: Some(1) }
    /// for `reference_to(X)` / has_one / belongs_to ; `has_many` produces
    /// Cardinality { min: 0, max: None } (unbounded) or { min: 0, max: Some(N) }
    /// when the DSL passes `max: N`. See Reference::single / belongs_to /
    /// has_one / many / many_with_max constructors for the canonical builders.
    pub cardinality: Cardinality,
    /// Which DSL keyword produced this Reference. Preserves authored
    /// intent (has_one vs belongs_to vs has_many vs reference_to) past
    /// parsing ; round-trips via ReferenceKind::as_str into the
    /// canonical IR dump.
    pub kind: ReferenceKind,
}

#[derive(Debug, Clone)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
    /// Literal/value-spec args the policy passes to its triggered
    /// command, on top of the upstream event's data. Ordered
    /// (key, ValueSpec) pairs parsed from `with key: "literal"` lines.
    /// The adapters-as-bluebook arc uses this for gap #1 : a policy
    /// firing `Primitive::Process.Spawn` carries the literal `cmd`
    /// and `result_into` the retired :exec resolver used to inline.
    /// For this slice only `ValueSpec::Literal` is produced ; the
    /// state-aware specs (FromState/templating) are deferred.
    pub with: Vec<(String, ValueSpec)>,
}

impl Policy {
    /// gap #1b (adapters-as-bluebook) — `on "Aggregate.Event"` is an
    /// aggregate-qualified subscription : the policy fires ONLY for
    /// events of that name emitted BY that aggregate. The bare form
    /// `on "Event"` matches by name across every aggregate (the
    /// historical, backward-compatible behaviour). The qualifier is
    /// the substring before the first `.` ; absent when the form is
    /// bare. We split on the first `.` so an event name never contains
    /// one (they're PascalCase identifiers, so this is safe).
    pub fn event_qualifier(&self) -> Option<&str> {
        self.on_event.split_once('.').map(|(agg, _)| agg)
    }

    /// The bare event name with any `Aggregate.` qualifier stripped.
    /// Validators + the policy index key on this so a qualified
    /// subscription still resolves against the corpus's emitted-event
    /// set (which carries bare names only).
    pub fn event_name(&self) -> &str {
        match self.on_event.split_once('.') {
            Some((_, ev)) => ev,
            None => self.on_event.as_str(),
        }
    }
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
/// kwarg-ref and applies the op to each candidate record. In tests
/// list membership : the record field must equal one element of a
/// literal list (`where field: { in: [a, b] }`). (i101)
#[derive(Debug, Clone)]
pub enum WhereOp {
    Eq,
    Ne,
    Gt,
    Gte,
    Lt,
    Lte,
    In,
    Resolved,
    NoneInState,
    MemberOf,
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

/// One declared view (i254). Mirrors
/// `Hecks::BluebookModel::Structure::View`. Different portals read the
/// same aggregate through different views ; the view declaration is the
/// single source of truth for "which attributes does this role see".
///
/// `show_all = true` projects every aggregate attribute, then appends
/// `fields` as extras (customer view typically lists the explicit subset
/// with `show_all = false` ; admin view typically uses `show_all = true`
/// plus a few internal fields). `show_all = false` projects only the
/// explicit `fields` list.
#[derive(Debug, Clone)]
pub struct View {
    pub name: String,
    pub show_all: bool,
    pub fields: Vec<String>,
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

/// f4 — one declared aggregate-level invariant. `name` is the rule's
/// stable identifier (the string passed to `invariant "..."`) ; it doubles
/// as the human-readable message when the rule is violated. `expression`
/// is the source text of the `holds_when { ... }` predicate — the same
/// single-line predicate grammar a `given` carries, evaluated against the
/// post-mutation state. Round-trips byte-identically through
/// canonical_ir.rb / dump.rs.
#[derive(Debug, Clone)]
pub struct Invariant {
    pub name: String,
    pub expression: String,
}

/// Multiplicity bounds for a Reference. `min` is the inclusive lower
/// bound (0 for optional, 1+ for required at_least). `max` is the
/// inclusive upper bound when Some, or `None` for unbounded collections.
///
/// Defaults per DSL keyword :
///   reference_to / has_one / belongs_to → { min: 0, max: Some(1) }
///   has_many                            → { min: 0, max: None }
///   has_many _, max: N                  → { min: 0, max: Some(N) }
///   has_many _, at_least: K, max: N     → { min: K, max: Some(N) }
///
/// Mirrors Ruby's Reference#cardinality { min:, max: } hash shape so
/// the parity contract dumps byte-identically across both parsers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cardinality {
    pub min: usize,
    pub max: Option<usize>,
}

/// Which DSL keyword produced this Reference. The IR carries the
/// authored intent past parsing so projections (mermaid diagram,
/// macrophage validators) can honor the original declaration rather
/// than collapsing all forms onto a single multiplicity shape.
///
/// Variants :
///   BelongsTo          — `belongs_to X` ; dependent side, single.
///   HasOne             — `has_one X` ; owner side, single.
///   HasMany            — `has_many Xs` ; owner side, collection.
///   LegacyReferenceTo  — `reference_to(X)` ; pre-Sprint-7 unidir form,
///                          treated as BelongsTo for IR shape but kept
///                          distinct so the retire-reference-to-keyword
///                          macrophage can flag call sites.
///
/// Round-trips through `ReferenceKind::as_str()` for serde / canonical-
/// IR dump. Ruby's reference.rb mirrors via `attr_reader :kind`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReferenceKind {
    BelongsTo,
    HasOne,
    HasMany,
    /// `reference_to(X)` — pre-Sprint-7 unidir form. Treated as BelongsTo
    /// for IR shape but kept distinct so the retire-reference-to-keyword
    /// macrophage can identify legacy call sites for migration.
    LegacyReferenceTo,
}

impl ReferenceKind {
    /// Canonical keyword string for round-trip / serialization. Mirrors
    /// BlockParser::name pattern — each variant carries the DSL keyword
    /// that authored it, so dump.rs / canonical_ir.rb can emit the
    /// authored intent rather than a Rust-internal enum tag.
    pub fn as_str(&self) -> &'static str {
        match self {
            ReferenceKind::BelongsTo => "belongs_to",
            ReferenceKind::HasOne => "has_one",
            ReferenceKind::HasMany => "has_many",
            ReferenceKind::LegacyReferenceTo => "reference_to",
        }
    }
}

impl Reference {
    /// Construct a single-cardinality Reference defaulting to
    /// LegacyReferenceTo — kept for existing call sites that pre-date
    /// the kind field. New code should use belongs_to() / has_one() /
    /// has_many() / many_with_max() explicitly so the authored intent
    /// rides into the IR.
    pub fn single(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(1) },
            kind: ReferenceKind::LegacyReferenceTo,
        }
    }

    /// Construct a Reference from `belongs_to X`. Single cardinality on
    /// the dependent side ; identity-only ; cross-aggregate.
    pub fn belongs_to(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(1) },
            kind: ReferenceKind::BelongsTo,
        }
    }

    /// Construct a Reference from `has_one X`. Single cardinality on
    /// the owner side ; mirrors belongs_to in shape, differs in intent.
    pub fn has_one(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(1) },
            kind: ReferenceKind::HasOne,
        }
    }

    /// Construct an unbounded `has_many Xs` Reference — max: None means
    /// the collection has no declared upper bound.
    pub fn many(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: None },
            kind: ReferenceKind::HasMany,
        }
    }

    /// Construct a `has_many Xs, max: N` Reference — bounded collection.
    pub fn many_with_max(name: String, target: String, domain: Option<String>, max: usize) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(max) },
            kind: ReferenceKind::HasMany,
        }
    }
}
