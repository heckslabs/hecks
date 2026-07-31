use std::fmt;

#[derive(Debug, Clone)]
pub struct Domain {
    pub name: String,
    pub version: Option<String>,
    pub category: Option<String>,
    pub vision: Option<String>,
    pub classification: Option<String>,
    pub aggregates: Vec<Aggregate>,
    pub read_models: Vec<ReadModel>,
    pub policies: Vec<Policy>,
    pub fixtures: Vec<Fixture>,
    pub entrypoint: Option<String>,
    pub sections: Vec<Section>,
    pub process_managers: Vec<ProcessManager>,
    pub cadences: Vec<Cadence>,
    pub block_grammars: Vec<BlockGrammar>,
}

#[derive(Debug, Clone)]
pub struct Cadence {
    pub name: String,
    pub interval: String,
    pub dispatches: Vec<CadenceDispatch>,
}

#[derive(Debug, Clone)]
pub struct CadenceDispatch {
    pub command_name: String,
    pub attrs: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub struct BlockGrammar {
    pub name: String,
    pub blocks: Vec<BlockGrammarEntry>,
}

#[derive(Debug, Clone)]
pub struct BlockGrammarEntry {
    pub keyword: String,
    pub parser: BlockParser,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockParser {
    Aggregate,
    ReadModel,
    Policy,
    ProcessManager,
    Cadence,
    Section,
    Fixture,
}

impl BlockParser {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "parse_aggregate" => Some(Self::Aggregate),
            "parse_read_model" => Some(Self::ReadModel),
            "parse_policy" => Some(Self::Policy),
            "parse_process_manager" => Some(Self::ProcessManager),
            "parse_cadence" => Some(Self::Cadence),
            "parse_section" => Some(Self::Section),
            "parse_fixture" => Some(Self::Fixture),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::Aggregate => "parse_aggregate",
            Self::ReadModel => "parse_read_model",
            Self::Policy => "parse_policy",
            Self::ProcessManager => "parse_process_manager",
            Self::Cadence => "parse_cadence",
            Self::Section => "parse_section",
            Self::Fixture => "parse_fixture",
        }
    }
}

impl BlockGrammar {
    pub fn canonical_bluebook() -> Self {
        Self {
            name: "Bluebook".into(),
            blocks: vec![
                entry("aggregate", BlockParser::Aggregate),
                entry("read_model", BlockParser::ReadModel),
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
    BlockGrammarEntry {
        keyword: keyword.into(),
        parser,
    }
}

#[derive(Debug, Clone)]
pub struct ProcessManager {
    pub name: String,
    pub correlates_by: String,
    pub starts_on: String,
    pub ends_on: Option<String>,
    pub states: Vec<String>,
    pub handlers: Vec<ProcessManagerHandler>,
}

#[derive(Debug, Clone)]
pub struct ProcessManagerHandler {
    pub event_type: String,
    pub from_state: String,
    pub to_state: String,
    pub dispatches: Vec<DispatchSpec>,
    pub set_specs: Vec<(String, ValueSpec)>,
}

#[derive(Debug, Clone)]
pub struct DispatchSpec {
    pub command_name: String,
    pub with_spec: Vec<(String, ValueSpec)>,
    pub for_each: Option<ForEachSpec>,
}

#[derive(Debug, Clone)]
pub struct ForEachSpec {
    pub source_context: Option<String>,
    pub source_aggregate: String,
    pub query_name: String,
    pub query_inputs: Vec<(String, ValueSpec)>,
}

#[derive(Debug, Clone)]
pub enum ValueSpec {
    Literal {
        value: String,
    },
    FromEvent {
        name: String,
        default: Option<String>,
    },
    FromPm {
        name: String,
        default: Option<String>,
    },
    FromIter {
        field: String,
    },
}

#[derive(Debug, Clone)]
pub struct Section {
    pub title: String,
    pub rows: Vec<SectionRow>,
}

#[derive(Debug, Clone)]
pub struct SectionRow {
    pub label: String,
    pub field: String,
}

#[derive(Debug, Clone)]
pub struct UnknownKeyword {
    pub keyword: String,
    pub suggestion: String,
}

#[derive(Debug, Clone)]
pub struct Aggregate {
    pub name: String,
    pub description: Option<String>,
    pub context: Option<String>,
    pub category: Option<String>,
    pub bluebook_version: Option<String>,
    pub identified_by: Option<String>,
    pub attributes: Vec<Attribute>,
    pub factories: Vec<Factory>,
    pub commands: Vec<Command>,
    pub queries: Vec<Query>,
    pub value_objects: Vec<ValueObject>,
    pub entities: Vec<Entity>,
    pub references: Vec<Reference>,
    pub lifecycle: Option<Lifecycle>,
    pub invariants: Vec<Invariant>,
    pub views: Vec<View>,
    pub unknown_keywords: Vec<UnknownKeyword>,
    pub realm_path: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ReadModel {
    pub name: String,
    pub description: Option<String>,
    pub reference_name: String,
    pub reference_target: String,
    pub aggregate_heads: Vec<AggregateHead>,
}

#[derive(Debug, Clone)]
pub struct AggregateHead {
    pub aggregate: String,
    pub name: String,
    pub many: bool,
}

#[derive(Debug, Clone)]
pub struct Attribute {
    pub name: String,
    pub attr_type: String,
    pub default: Option<String>,
    pub list: bool,
    pub optional: bool,
    pub enum_values: Vec<String>,
    pub pattern: Option<String>,
    pub hint: Option<String>,
    pub logged: bool,
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
    pub redirects_native: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Query {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub wheres: Vec<WhereClause>,
    pub order_by: Option<OrderBy>,
    pub limit: Option<LimitSpec>,
    pub reduction: Option<Reduction>,
    pub group_by: Option<String>,
    pub scope_to: Option<String>,
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
    pub invalid_op: Option<String>,
}

#[derive(Debug, Clone)]
pub enum MutationOp {
    Set,
    Append,
    Increment,
    Decrement,
    Toggle,
    Delete,
    Multiply,
    Clamp,
    Decay,
    Remove,
    AppendUnique,
}

#[derive(Debug, Clone)]
pub struct ValueObject {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub invariants: Vec<Invariant>,
    pub derivations: Vec<Derivation>,
    pub members: Vec<Vec<(String, String)>>,
    /// A one_of DECLARED but left empty is indistinguishable from no one_of at
    /// all if only `members` is carried — both are empty. Recording the
    /// declaration lets the language judge an empty closed set, the same way an
    /// empty attribute name survives into the IR and is judged there.
    pub closed_set: bool,
}

#[derive(Debug, Clone)]
pub struct Entity {
    pub name: String,
    pub description: Option<String>,
    pub attributes: Vec<Attribute>,
    pub commands: Vec<Command>,
    pub queries: Vec<Query>,
    pub lifecycle: Option<Lifecycle>,
    pub identified_by: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Reference {
    pub name: String,
    pub target: String,
    pub domain: Option<String>,
    pub cardinality: Cardinality,
    pub kind: ReferenceKind,
    // A named reference on a COMMAND is an argument, so it may be optional the
    // same way a plain attribute is. Ruby reaches this through the shared
    // attribute collector ; here the two shapes are separate and it has to be
    // carried explicitly, or the implied reference-attribute loses the fact.
    pub optional: bool,
}

#[derive(Debug, Clone)]
pub struct Policy {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
    pub target_domain: Option<String>,
    pub with: Vec<(String, ValueSpec)>,
    pub wheres: Vec<WhereClause>,
    pub for_each: Option<ForEachSpec>,
    pub extra_dispatches: Vec<DispatchSpec>,
}

impl Policy {
    pub fn event_qualifier(&self) -> Option<&str> {
        crate::naming::qualifier(&self.on_event)
    }

    pub fn event_name(&self) -> &str {
        crate::naming::unqualified(&self.on_event)
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

#[derive(Debug, Clone)]
pub enum WhereOp {
    Eq,
    Ne,
    Gt,
    Gte,
    Lt,
    Lte,
    In,
    NoneInState,
    Contains,
}

#[derive(Debug, Clone)]
pub struct OrderBy {
    pub field: String,
    pub direction: Direction,
}

#[derive(Debug, Clone)]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Debug, Clone)]
pub struct LimitSpec {
    pub value: String,
}

#[derive(Debug, Clone)]
pub enum Reduction {
    Count,
    Sum(String),
    Max(String),
    Min(String),
    Median(String),
}

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
                if let Some(ref emits) = cmd.emits {
                    write!(f, " -> {}", emits)?;
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

#[derive(Debug, Clone)]
pub struct Invariant {
    pub name: String,
    pub expression: String,
}

#[derive(Debug, Clone)]
pub struct Derivation {
    pub name: String,
    pub return_type: String,
    pub params: Vec<String>,
    pub expression: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cardinality {
    pub min: usize,
    pub max: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReferenceKind {
    BelongsTo,
    HasOne,
    HasMany,
    LegacyReferenceTo,
}

impl ReferenceKind {
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
    pub fn single(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name,
            target,
            domain,
            cardinality: Cardinality {
                min: 0,
                max: Some(1),
            },
            optional: false,
            kind: ReferenceKind::LegacyReferenceTo,
        }
    }

    pub fn belongs_to(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name,
            target,
            domain,
            cardinality: Cardinality {
                min: 0,
                max: Some(1),
            },
            optional: false,
            kind: ReferenceKind::BelongsTo,
        }
    }

    pub fn has_one(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name,
            target,
            domain,
            cardinality: Cardinality {
                min: 0,
                max: Some(1),
            },
            optional: false,
            kind: ReferenceKind::HasOne,
        }
    }

    pub fn many(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name,
            target,
            domain,
            cardinality: Cardinality { min: 0, max: None },
            optional: false,
            kind: ReferenceKind::HasMany,
        }
    }

    pub fn many_with_max(name: String, target: String, domain: Option<String>, max: usize) -> Self {
        Reference {
            name,
            target,
            domain,
            cardinality: Cardinality {
                min: 0,
                max: Some(max),
            },
            optional: false,
            kind: ReferenceKind::HasMany,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Factory {
    pub name: String,
    pub description: Option<String>,
    pub role: Option<String>,
    pub produces: Option<String>,
    pub attributes: Vec<Attribute>,
    pub references: Vec<Reference>,
    pub emits: Option<String>,
    pub emits_identified_by: Option<String>,
    pub givens: Vec<Given>,
    pub mutations: Vec<Mutation>,
}
