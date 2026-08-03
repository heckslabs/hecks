use std::fmt;

// THE CLOSED SETS COME FROM THE LANGUAGE, not from here. `MutationOp` and
// `WhereOp` are declared by `Vocabulary` in the bluebook chapter and PROJECTED
// into Rust source by `bin/ir_vocabulary` ; re-exported so every consumer's
// `use crate::ir::*` reaches them at the same path as when they were written
// here by hand. Both had drifted while they were hand-written — eleven mutation
// ops against the four the language admits, and a ninth where-op it never
// declared — which is the whole argument for projecting them.
pub use super::ir_vocabulary::{MutationOp, WhereOp};

// THE CATEGORY SHAPES COME FROM THE LANGUAGE TOO, one rung further along than
// the closed sets above. `bin/ir_structs` reads the thirteen categories the
// language uses to describe itself, plus the `derived:` column of
// `assembly/contracts.rb` — the one thing the language cannot say, which fields
// the IR does not carry and why — and emits these nine as Rust source.
//
// Only ten, and that is the honest number: the rest of this file is here
// because the language and Rust genuinely disagree about it, or because the
// language never declared it at all. `ir_structs.rs`'s header names every one
// of those and says which. Re-exported so `use crate::ir::*` reaches them at
// the path they were written at by hand.
//
// ProcessManager and ProcessManagerHandler joined the list once the LANGUAGE
// was corrected, not Rust: it declared `ends_on` required where both runtimes
// have always held it optional, and `from_state` optional where neither runtime
// can parse a leg without one. Both structs came out of the generator identical,
// field for field and in order, to the hand-written ones deleted from here.
//
// WhereClause joined them once the LANGUAGE grew a word rather than once Rust
// changed: `op` has always been a `WhereOp` here, and the set it reads is one
// the language declares (Vocabulary::QueryComparator), but nothing LINKED the
// two, so the generator refused to guess the typing and said so. `Filter.op`
// now says `admits: Vocabulary::QueryComparator`, and what comes out is
// identical, field for field, to the struct deleted from here.
pub use super::ir_structs::{
    Aggregate, Command, Domain, Entity, Given, ProcessManager, ProcessManagerHandler, Transition,
    WhereClause,
};

/// `with_spec`'s VALUE is the same text `IR.render_value` put on the wire —
/// a leading colon means an argument the event (or process manager memory)
/// carried, anything else is a literal — and neither runtime has ever needed
/// more than that to dispatch.
///
/// Used to be `Vec<(String, ValueSpec)>`, where `ValueSpec` was an enum with
/// `FromEvent`/`FromPm`/`FromIter` variants alongside `Literal` — a Rust-only
/// reading of a bluebook's `from_event(...)`/`from_pm(...)`/`from_iter(...)`
/// sentinel syntax. No Ruby method by any of those three names exists in this
/// project or in Hecks ; `bin/ir_rust`'s own generator comment said as much —
/// "ALWAYS A LITERAL, and the colon stays on" — because Ruby's wire format
/// never carries anything else. Worse than merely unreachable : the wire
/// flattening (`ir_json::value_spec_text`) dropped the leading colon for
/// `FromEvent`/`FromPm` while `Literal` kept it, so the one time this path was
/// traced end to end, the explicit sentinel form would have silently
/// round-tripped into being read as a plain string instead of an event/memory
/// lookup — the opposite of what it was for. `with_spec` now carries exactly
/// what the language declares `Binding`'s value to be : a plain string.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DispatchSpec {
    pub command_name: String,
    pub with_spec: Vec<(String, String)>,
}

// NO `identity_key`. Both `Aggregate` and `Entity` used to answer "the one
// path a repository addresses records by" — `identified_by.first()` — and the
// only thing that ever asked was `PersistenceAdapter::id_for_command`, which
// minted. A repository is handed an id ALREADY DERIVED: `identity::of` follows
// every declared path and joins them on `Naming::IDENTITY_JOIN`. So a store
// never had the question, and answering it with the first of several paths was
// a wrong answer nobody heard.


#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AggregateHead {
    pub aggregate: String,
    /// SPELLED `as`, the way Ruby spells it and the way the wire has always
    /// carried it. A Rust keyword, so it takes the one mechanical escape a
    /// generator has to know: `r#`.
    pub r#as: String,
    pub many: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Attribute {
    pub name: String,
    /// SPELLED `type`, matching Ruby, escaped because Rust reserves the word.
    pub r#type: String,
    pub default: Option<String>,
    pub list: bool,
    pub optional: bool,
    pub enum_values: Vec<String>,
    pub pattern: Option<String>,
    /// The closed set this value must belong to, named where it was declared —
    /// `"Vocabulary::MutationOp"`. Qualified by the aggregate that holds it,
    /// because a closed set is a value object INSIDE an aggregate.
    ///
    /// The NAME crosses, not the members: each runtime resolves it against its
    /// own IR, so neither keeps a copy of a set the other declared. Unlike
    /// `enum_values` beside it — which `one_of` desugars away into a synthesised
    /// value object — this names a set that already exists and is left alone.
    pub admits: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Query {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub wheres: Vec<WhereClause>,
    pub order_by: Option<OrderBy>,
    pub limit: Option<LimitSpec>,
    // THE EIGHT SPECIFICATION OPTIONS Ruby's `QuerySpecification::Common::Options`
    // has carried since the language could say them — offset/cursor/consistency/
    // freshness/authorize/nulls/inspect_query/use_index. Absent, not `None`, on the
    // wire: Ruby's `extra_options_to_h` drops a key entirely when its value is nil
    // (or `[]`, or null_semantics at its native default), so a query that never
    // declares one of these carries no key for it at all — see `ir_json.rs`'s
    // `query_options_to_value` for the matching omission on this side.
    pub offset: Option<OffsetSpec>,
    pub cursor: Option<CursorSpec>,
    pub consistency: Option<ConsistencySpec>,
    pub freshness: Option<FreshnessSpec>,
    pub authorization: Option<AuthorizationSpec>,
    pub null_semantics: Option<NullSemanticsSpec>,
    pub inspection: Option<InspectionSpec>,
    pub index_hints: Vec<IndexHint>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Mutation {
    pub target: String,
    pub op: MutationOp,
    pub source: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ValueObject {
    pub name: String,
    pub attributes: Vec<Attribute>,
    pub invariants: Vec<Invariant>,
    pub members: Vec<Vec<(String, String)>>,
    /// A one_of DECLARED but left empty is indistinguishable from no one_of at
    /// all if only `members` is carried — both are empty. Recording the
    /// declaration lets the language judge an empty closed set, the same way an
    /// empty attribute name survives into the IR and is judged there.
    pub closed_set: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
}

impl Policy {
    pub fn event_qualifier(&self) -> Option<&str> {
        crate::naming::qualifier(&self.on_event)
    }

    pub fn event_name(&self) -> &str {
        crate::naming::unqualified(&self.on_event)
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Lifecycle {
    pub field: String,
    pub default: String,
    pub transitions: Vec<Transition>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OrderBy {
    pub field: String,
    pub direction: Direction,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LimitSpec {
    pub value: String,
}

// THE OPTION STRUCTS THEMSELVES. Each mirrors one `QuerySpecification::Common`
// struct field for field — `OffsetSpec`/`CursorSpec`/`ConsistencySpec`/
// `FreshnessSpec`/`AuthorizationSpec`/`NullSemantics`/`InspectionSpec`/
// `IndexHint` — with the same asymmetry Ruby's own `to_h` methods carry: most
// stringify with plain `.to_s` (a declared symbol loses its leading colon),
// but `OffsetSpec`/`CursorSpec` stringify with `render_value`, which keeps the
// colon on a symbol. `cursor :after` is the one place that colon actually
// shows on the wire — every other field's declared as a symbol too but its
// Ruby struct strips it. Rust's parser (`parse_blocks.rs`) does the same
// per-field stripping so the two sides render identical strings.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OffsetSpec {
    pub value: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CursorSpec {
    pub value: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConsistencySpec {
    pub mode: String,
    pub timeout: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FreshnessSpec {
    pub mode: String,
    pub max_age: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AuthorizationSpec {
    pub policy: String,
    pub tenant: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct NullSemanticsSpec {
    pub mode: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct InspectionSpec {
    pub mode: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct IndexHint {
    pub name: String,
}

// `ReadModel` STAYS HAND-WRITTEN, joining `Query` for the same reason. The
// language's own self-description (`lib/hecksagain/language/bluebook/projection.bluebook`)
// models a read model's options as one generic fold — `options: list_of(ProjectionOption)`,
// four flat strings (option/key/value/at) — because that is how the META-VALIDATOR
// judges an `offset`/`cursor`/... line while it is being declared. But the REAL
// runtime object booted from a `.bluebook` file (`Hecksagain::Bluebook::IR::ReadModel`)
// inherits `QuerySpecification::ReadModel::Specification`, the identical typed
// carrier `Query` inherits — so the wire `ReadModel` produces is shaped like
// `Query`'s, not like the meta-domain's fold. `bin/ir_structs` can only read the
// meta-domain, so it would generate the fold's shape and be wrong about the
// wire; pulled out of `ROOTS` and hand-written here instead, the same call this
// file already made for `Query` over `limit`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReadModel {
    pub name: String,
    pub description: Option<String>,
    pub reference_name: String,
    pub reference_target: String,
    pub aggregate_heads: Vec<AggregateHead>,
    pub offset: Option<OffsetSpec>,
    pub cursor: Option<CursorSpec>,
    pub consistency: Option<ConsistencySpec>,
    pub freshness: Option<FreshnessSpec>,
    pub authorization: Option<AuthorizationSpec>,
    pub null_semantics: Option<NullSemanticsSpec>,
    pub inspection: Option<InspectionSpec>,
    pub index_hints: Vec<IndexHint>,
}

impl fmt::Display for Domain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{}", self.name)?;
        let agg_count = self.aggregates.len();
        for (ai, agg) in self.aggregates.iter().enumerate() {
            let is_last_agg = ai == agg_count - 1;
            let prefix = if is_last_agg {
                "└──"
            } else {
                "├──"
            };
            let cont = if is_last_agg { "    " } else { "│   " };
            writeln!(
                f,
                "{} {} — {}",
                prefix,
                agg.name,
                agg.description.as_deref().unwrap_or("")
            )?;
            let cmd_count = agg.commands.len();
            for (ci, cmd) in agg.commands.iter().enumerate() {
                let cmd_prefix = if ci == cmd_count - 1 {
                    "└──"
                } else {
                    "├──"
                };
                write!(f, "{}{} {}", cont, cmd_prefix, cmd.name)?;
                if !cmd.emits.is_empty() {
                    write!(f, " -> {}", cmd.emits.join(", "))?;
                }
                writeln!(f)?;
            }
        }
        if !self.policies.is_empty() {
            for pol in &self.policies {
                writeln!(
                    f,
                    "  {} : {} -> {}",
                    pol.name, pol.on_event, pol.trigger_command
                )?;
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Invariant {
    pub description: String,
    pub canonical: String,
}

