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

#[derive(Debug)]
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

#[derive(Debug)]
pub struct Aggregate {
    pub name: String,
    pub description: Option<String>,
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

#[derive(Debug)]
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

#[derive(Debug)]
pub struct Query {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug)]
pub struct Given {
    pub expression: String,
    pub message: Option<String>,
}

#[derive(Debug)]
pub struct Mutation {
    pub field: String,
    pub operation: MutationOp,
    pub value: String,
}

#[derive(Debug)]
pub enum MutationOp {
    Set,
    Append,
    Increment,
    Decrement,
    Toggle,
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

#[derive(Debug)]
pub struct ValueObject {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
}

#[derive(Debug)]
pub struct Reference {
    pub name: String,
    pub target: String,
    pub domain: Option<String>,
}

#[derive(Debug)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
}

#[derive(Debug)]
pub struct Lifecycle {
    pub field: String,
    pub default: String,
    pub transitions: Vec<Transition>,
}

#[derive(Debug)]
pub struct Transition {
    pub command: String,
    pub to_state: String,
    pub from_state: Option<String>,
}

#[derive(Debug)]
pub struct Fixture {
    /// Optional logical identifier (set by the block form's first positional
    /// arg). None for inline-form fixtures.
    pub name: Option<String>,
    pub aggregate_name: String,
    pub attributes: Vec<(String, String)>,
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
