//! What each phrase means: the blocks of a sentence file lowered into `ir` structs.
//!
//! An aggregate reads its blocks in any order and resolves names once it has them all, so
//! `It has:` may come before or after the value objects it names, and a command may name a field
//! declared further down. Every unresolved name is refused with the names that are in scope.

use super::changes::Change;
use super::names::{camel, scalar, snake, spoken, SCALARS};
use super::{column, Matched, Parser, Scope, Step};
use crate::build::identity;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// A type phrase written in the file, resolved once the aggregate's value objects are known.
pub(super) struct TypeUse {
    line: usize,
    col: usize,
    words: String,
    /// Names an aggregate (`reference to …`, `has many …`), not a scalar or a value object.
    reference: bool,
}

struct Identity {
    line: usize,
    col: usize,
    fields: Vec<String>,
}

struct Transition {
    line: usize,
    col: usize,
    command: String,
    from: String,
    to: String,
}

struct LifecycleSpec {
    field: String,
    default: String,
    transitions: Vec<Transition>,
    marks: Vec<(String, Vec<String>)>,
}

/// A field a sentence names, with where it named it.
pub(super) struct FieldUse {
    pub name: String,
    pub line: usize,
    pub col: usize,
}

struct CommandSpec {
    name: String,
    role: Option<String>,
    roles: Vec<String>,
    goal: Option<String>,
    references: Option<String>,
    args: Vec<FieldUse>,
    /// Arguments of its own, typed where they are written (`It takes:`).
    takes: Vec<(ir::Attribute, TypeUse)>,
    givens: Vec<ir::Given>,
    ensures: Vec<ir::Given>,
    from: Option<ir::CommandFrom>,
    changes: Vec<Change>,
    emits: Vec<String>,
}

/// A condition read from a rule, a given or a where.
pub(super) struct Cond {
    pub canonical: String,
    /// The field the condition is about; none for a condition written as an expression.
    pub field: Option<FieldUse>,
    pub value: Option<String>,
}

/// What a policy does when its event is announced.
enum Reaction {
    /// Runs a command of the chapter.
    Run(String),
    /// Asks the outside for something, by the need's name in the domain's words.
    Ask(String),
}

/// A policy as written, before its event and command are looked up in the chapter.
struct PolicySpec {
    name: String,
    line: usize,
    col: usize,
    /// The event announced, the aggregate it is said to come from, and where it was written.
    event: Option<(String, Option<String>, usize, usize)>,
    reaction: Option<(Reaction, Vec<FieldUse>, usize, usize)>,
}

/// Everything read of one aggregate before its names are resolved.
pub(super) struct AggState {
    pub agg: ir::Aggregate,
    attr_types: Vec<TypeUse>,
    /// The arguments each query (by index in `agg.queries`) wrote, to be typed once all is read.
    pub query_args: Vec<(usize, Vec<(ir::Attribute, TypeUse)>)>,
    /// The type phrase of attribute `.1` of value object `.0`, resolved once all are read.
    vo_types: Vec<(usize, usize, TypeUse)>,
    identity: Option<Identity>,
    lifecycle: Option<LifecycleSpec>,
    commands: Vec<CommandSpec>,
    pub checks: Vec<FieldUse>,
}

impl Parser<'_> {
    /// Reads the whole file: one `Domain:` and the aggregates under it.
    pub(super) fn file(&mut self) -> ParseResult<ir::Bluebook> {
        self.types = self.declared_types();
        let mut scope = Scope::top();
        let Some(Step::Phrase(header)) = self.step(&mut scope, "File", false)? else {
            return Err(self.error(1, 1, "this file is empty; it starts with `Domain: <name>`"));
        };
        let mut chapter = ir::Bluebook {
            name: camel(&header.text_of("name")),
            ..Default::default()
        };
        // An indented paragraph under the `Domain:` line says what the domain is for.
        let mut vision = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut vision, "Vision", true)? {
            match step {
                Step::Prose { text } => chapter.vision = Some(text),
                Step::Phrase(m) if m.id == "classification" => {
                    let kind = m.text_of("kind").to_lowercase();
                    if !matches!(kind.as_str(), "core" | "supporting" | "generic") {
                        return Err(self.error(
                            m.line,
                            m.col_of("kind"),
                            format!("'{kind}' is not a kind of domain; it is core, supporting or generic"),
                        ));
                    }
                    chapter.classification = Some(kind);
                }
                Step::Phrase(m) if m.id == "namespace" => chapter.namespace = Some(m.text_of("name")),
                Step::Phrase(m) if m.id == "version" => chapter.version = Some(m.text_of("version")),
                Step::Phrase(m) if m.id == "attaches" => {
                    chapter.attaches_to = m.capture("contexts").items.iter().map(|item| camel(item)).collect();
                }
                Step::Phrase(m) if m.id == "provides" => {
                    let capability = m.text_of("capability");
                    let mut rows = Scope::inside(m.indent);
                    while let Some(Step::Phrase(row)) = self.step(&mut rows, "Provides", false)? {
                        chapter.provisions_push(&capability, &row);
                    }
                }
                Step::Phrase(m) => return Err(self.unmeant(&m)),
            }
        }
        // The aggregates follow at the top level, as flat as the `Domain:` line.
        let mut aggregates = Scope::top();
        aggregates.first = false;
        let mut policies: Vec<PolicySpec> = Vec::new();
        while let Some(step) = self.step(&mut aggregates, "Domain", false)? {
            match step {
                Step::Phrase(m) if m.id == "aggregate" => {
                    let aggregate = self.aggregate(&m)?;
                    chapter.aggregates.push(aggregate);
                }
                Step::Phrase(m) if m.id == "policy" => policies.push(self.policy(&m)?),
                Step::Phrase(m) if m.id == "report" => {
                    let model = self.report(&m)?;
                    chapter.read_models.push(model);
                }
                Step::Phrase(m) => return Err(self.unmeant(&m)),
                Step::Prose { .. } => {}
            }
        }
        chapter.policies = self.policies_of(&chapter, policies)?;
        if let Some(line) = self.lines.get(self.pos) {
            return Err(self.error(
                line.number,
                1,
                "a file holds one domain; this line is outside it. Start another file for another domain",
            ));
        }
        Ok(chapter)
    }

    /// Reads one `Policy:` block: the event it waits for and what it does then.
    fn policy(&mut self, header: &Matched) -> ParseResult<PolicySpec> {
        let mut spec = PolicySpec {
            name: camel(&header.text_of("name")),
            line: header.line,
            col: header.base_col,
            event: None,
            reaction: None,
        };
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Policy", false)? {
            let Step::Phrase(m) = step else { continue };
            match m.id {
                "whenever" | "whenever_by" => {
                    if spec.event.is_some() {
                        return Err(self.error(m.line, m.base_col, "a policy waits for one event; this is a second `Whenever`"));
                    }
                    let owner = (m.id == "whenever_by").then(|| m.text_of("owner"));
                    spec.event = Some((m.text_of("event"), owner, m.line, m.col_of("event")));
                }
                "runs" | "runs_with" | "asked" | "asked_with" => {
                    if spec.reaction.is_some() {
                        return Err(self.error(m.line, m.base_col, "a policy does one thing; this is a second `Then`"));
                    }
                    let fields = if m.id.ends_with("with") { field_uses(&m, "fields") } else { Vec::new() };
                    let (reaction, slot) = if m.id.starts_with("runs") {
                        (Reaction::Run(camel(&m.text_of("command"))), "command")
                    } else {
                        (Reaction::Ask(snake(&m.text_of("need"))), "need")
                    };
                    spec.reaction = Some((reaction, fields, m.line, m.col_of(slot)));
                }
                _ => return Err(self.unmeant(&m)),
            }
        }
        Ok(spec)
    }

    /// Looks up the events and commands the policies name, now that every aggregate is read.
    fn policies_of(&self, chapter: &ir::Bluebook, specs: Vec<PolicySpec>) -> ParseResult<Vec<ir::Policy>> {
        let mut policies = Vec::new();
        for spec in specs {
            let Some((event, owner, event_line, event_col)) = spec.event else {
                return Err(self.error(spec.line, spec.col, "this policy has no `Whenever <event> is announced`"));
            };
            let Some((reaction, fields, then_line, then_col)) = spec.reaction else {
                return Err(self.error(spec.line, spec.col, "this policy does nothing; add `Then <command> runs` or `Then <need> is asked`"));
            };
            let source = self.event_source(chapter, &event, owner.as_deref(), event_line, event_col)?;
            let mut policy = ir::Policy {
                name: spec.name,
                on_event: Some(format!("{source}.{event}")),
                with_spec: fields.iter().map(|f| (f.name.clone(), format!(":{}", f.name))).collect(),
                ..Default::default()
            };
            match reaction {
                Reaction::Ask(need) => policy.ask = Some(need),
                Reaction::Run(command) => {
                    let found: Vec<(&ir::Aggregate, &ir::Command)> = chapter
                        .aggregates
                        .iter()
                        .flat_map(|a| a.commands.iter().map(move |c| (a, c)))
                        .filter(|(_, c)| c.name == command)
                        .collect();
                    let [(aggregate, target)] = found.as_slice() else {
                        let all: Vec<String> = chapter
                            .aggregates
                            .iter()
                            .flat_map(|a| a.commands.iter().map(|c| spoken(&c.name)))
                            .collect();
                        return Err(self.error(
                            then_line,
                            then_col,
                            format!("'{}' is not one command of this chapter. The commands are: {}", spoken(&command), all.join(", ")),
                        ));
                    };
                    for field in &fields {
                        if !target.attributes.iter().any(|a| a.name == field.name) {
                            let takes: Vec<String> = target.attributes.iter().map(|a| spoken(&a.name)).collect();
                            let takes = if takes.is_empty() { "nothing".to_string() } else { takes.join(", ") };
                            return Err(self.error(
                                field.line,
                                field.col,
                                format!("{} takes no '{}'. It takes: {takes}", spoken(&target.name), spoken(&field.name)),
                            ));
                        }
                    }
                    policy.trigger_command = Some(format!("{}.{}", aggregate.name, target.name));
                }
            }
            policies.push(policy);
        }
        Ok(policies)
    }

    /// The aggregate an announced event comes from: the one whose command announces it, or the
    /// one named outright for an event the outside announces.
    fn event_source(
        &self,
        chapter: &ir::Bluebook,
        event: &str,
        owner: Option<&str>,
        line: usize,
        col: usize,
    ) -> ParseResult<String> {
        if let Some(noun) = owner {
            return chapter
                .aggregates
                .iter()
                .find(|a| spoken(&a.name) == noun.to_lowercase())
                .map(|a| a.name.clone())
                .ok_or_else(|| {
                    let known: Vec<String> = chapter.aggregates.iter().map(|a| spoken(&a.name)).collect();
                    self.error(line, col, format!("there is no '{noun}' here. The aggregates are: {}", known.join(", ")))
                });
        }
        let sources: Vec<&ir::Aggregate> = chapter
            .aggregates
            .iter()
            .filter(|a| a.commands.iter().any(|c| c.emits.iter().any(|e| e == event)))
            .collect();
        match sources.as_slice() {
            [one] => Ok(one.name.clone()),
            [] => {
                let announced: Vec<String> = chapter
                    .aggregates
                    .iter()
                    .flat_map(|a| a.commands.iter().flat_map(|c| c.emits.iter().cloned()))
                    .collect();
                Err(self.error(
                    line,
                    col,
                    format!(
                        "no command announces {event}. The events announced are: {}. If the outside announces it, say `… is announced by an <aggregate>`",
                        announced.join(", ")
                    ),
                ))
            }
            _ => Err(self.error(line, col, format!("more than one aggregate announces {event}; say which with `… is announced by an <aggregate>`"))),
        }
    }

    /// A phrase the table admits that this front end has no meaning for yet.
    pub(super) fn unmeant(&self, m: &Matched) -> Diagnostic {
        self.error(
            m.line,
            m.base_col,
            format!("the phrase '{}' is admitted but the parser does not read it yet", m.id),
        )
    }

    fn aggregate(&mut self, header: &Matched) -> ParseResult<ir::Aggregate> {
        let mut st = AggState {
            agg: ir::Aggregate {
                name: camel(&header.text_of("name")),
                ..Default::default()
            },
            attr_types: Vec::new(),
            vo_types: Vec::new(),
            identity: None,
            lifecycle: None,
            commands: Vec::new(),
            checks: Vec::new(),
            query_args: Vec::new(),
        };
        let mut scope = Scope::inside(header.indent);
        let mut entities: Vec<(Matched, usize)> = Vec::new();
        while let Some(step) = self.step(&mut scope, "Aggregate", true)? {
            match step {
                Step::Prose { text } => st.agg.description = Some(text),
                Step::Phrase(m) => match m.id {
                    "identity" => self.identity(&m, &mut st)?,
                    "has" => self.has(&m, &mut st)?,
                    "value_object" | "value_object_with" => self.value_object(&m, &mut st)?,
                    "closed_set" => self.closed_set(&m, &mut st)?,
                    "value_fields" => self.value_fields(&m, &mut st)?,
                    "lifecycle" => self.lifecycle(&m, &mut st)?,
                    "command" => self.command(&m, &mut st)?,
                    "query" => self.query(&m, &mut st)?,
                    "aggregate_rule" | "precondition" => {
                        let cond = self.condition(&m)?;
                        st.checks.extend(cond.field);
                        let given = ir::Given {
                            description: Some(m.text_of("description")),
                            canonical: cond.canonical,
                        };
                        if m.id == "precondition" {
                            st.agg.preconditions.push(given);
                        } else {
                            st.agg.invariants.push(given);
                        }
                    }
                    "projected" => st.agg.projected_fields.push(ir::ProjectedField {
                        name: snake(&m.text_of("name")),
                        reference: snake(&m.text_of("reference")),
                        remote_field: snake(&m.text_of("remote")),
                    }),
                    "entity" => {
                        // Read once the aggregate's own blocks are, so its identity can name their value objects.
                        let from = self.pos;
                        while self.lines.get(self.pos).is_some_and(|line| line.indent > m.indent) {
                            self.pos += 1;
                        }
                        entities.push((m, from));
                    }
                    _ => return Err(self.unmeant(&m)),
                },
            }
        }
        self.entities_of(&mut st, entities)?;
        self.finish(st, header)
    }

    /// Reads the entity blocks an aggregate skipped over, with its value objects in reach.
    fn entities_of(&mut self, st: &mut AggState, entities: Vec<(Matched, usize)>) -> ParseResult<()> {
        let resume = self.pos;
        for (m, from) in entities {
            self.pos = from;
            let outer_before = self.outer.len();
            self.outer.extend(st.agg.value_objects.iter().cloned());
            let inner = self.aggregate(&m);
            self.outer.truncate(outer_before);
            let entity = super::entity::into_entity(inner?).map_err(|refused| self.error(m.line, m.base_col, refused))?;
            st.agg.entities.push(entity);
        }
        self.pos = resume;
        Ok(())
    }

    /// Refuses a sentence about some other aggregate than the one it stands in.
    fn same_owner(&self, m: &Matched, owner: &str, st: &AggState) -> ParseResult<()> {
        if camel(&m.text_of(owner)) == st.agg.name {
            return Ok(());
        }
        Err(self.error(
            m.line,
            m.col_of(owner),
            format!(
                "this is about '{}', but it stands in the aggregate '{}'",
                m.text_of(owner),
                spoken(&st.agg.name)
            ),
        ))
    }

    fn identity(&self, m: &Matched, st: &mut AggState) -> ParseResult<()> {
        self.same_owner(m, "owner", st)?;
        if st.identity.is_some() {
            return Err(self.error(m.line, m.base_col, "an aggregate is identified by one thing; this says it twice"));
        }
        st.identity = Some(Identity {
            line: m.line,
            col: m.col_of("fields"),
            fields: m.capture("fields").items.iter().map(|item| snake(item)).collect(),
        });
        Ok(())
    }

    fn has(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        for (attribute, used) in self.attribute_lines(header)? {
            st.agg.attributes.push(attribute);
            st.attr_types.push(used);
        }
        Ok(())
    }

    /// The attributes an `It has:` or `It takes:` block lists, each with the type phrase it wrote.
    pub(super) fn attribute_lines(&mut self, header: &Matched) -> ParseResult<Vec<(ir::Attribute, TypeUse)>> {
        let mut lines = Vec::new();
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Has", false)? {
            let Step::Phrase(m) = step else { continue };
            if !matches!(m.id, "attribute" | "attribute_with") {
                return Err(self.unmeant(&m));
            }
            let mut attribute = ir::Attribute {
                name: snake(&m.text_of("name")),
                ..Default::default()
            };
            if m.id == "attribute_with" {
                self.attribute_options(&m)?.onto(&mut attribute);
            }
            let shape = shape_of(&m.text_of("type"));
            shape.apply(&mut attribute);
            let used = TypeUse {
                line: m.line,
                col: m.col_of("type"),
                words: shape.words,
                reference: shape.relationship.is_some(),
            };
            lines.push((attribute, used));
        }
        Ok(lines)
    }

    fn value_object(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        let index = st.agg.value_objects.len();
        st.agg.value_objects.push(ir::ValueObject {
            name: camel(&header.text_of("name")),
            attributes: vec![ir::Attribute {
                name: "value".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        });
        if header.id == "value_object_with" {
            let options = self.attribute_options(header)?;
            if let Some(attribute) = st.agg.value_objects.get_mut(index).and_then(|vo| vo.attributes.first_mut()) {
                options.onto(attribute);
            }
        }
        let shape = shape_of(&header.text_of("type"));
        if let Some(attribute) = st.agg.value_objects.get_mut(index).and_then(|vo| vo.attributes.first_mut()) {
            shape.apply(attribute);
        }
        st.vo_types.push((
            index,
            0,
            TypeUse {
                line: header.line,
                col: header.col_of("type"),
                reference: shape.relationship.is_some(),
                words: shape.words,
            },
        ));
        self.value_rules(header, st, index)
    }

    /// `A band is one of: small, medium and large.`, with any rules under it.
    fn closed_set(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        let index = st.agg.value_objects.len();
        let values = header.capture("values").items;
        let mut set = crate::build::closed_sets::synthesize("value", &values);
        set.name = camel(&header.text_of("name"));
        st.agg.value_objects.push(set);
        self.value_rules(header, st, index)
    }

    /// The rules under a one-value block, each about `value`.
    fn value_rules(&mut self, header: &Matched, st: &mut AggState, index: usize) -> ParseResult<()> {
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "ValueObject", false)? {
            let Step::Phrase(m) = step else { continue };
            if m.id != "rule" {
                return Err(self.unmeant(&m));
            }
            let cond = self.condition(&m)?;
            if let Some(field) = cond.field.as_ref().filter(|field| field.name != "value") {
                return Err(self.unknown_field(field, &["value".to_string()]));
            }
            if let Some(vo) = st.agg.value_objects.get_mut(index) {
                vo.invariants.push(ir::Given {
                    description: Some(m.text_of("description")),
                    canonical: cond.canonical,
                });
            }
        }
        Ok(())
    }

    /// `A money has:` with one attribute per line and the rules about them.
    fn value_fields(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        let index = st.agg.value_objects.len();
        st.agg.value_objects.push(ir::ValueObject {
            name: camel(&header.text_of("name")),
            ..Default::default()
        });
        let mut checks: Vec<FieldUse> = Vec::new();
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Fields", false)? {
            let Step::Phrase(m) = step else { continue };
            match m.id {
                "field" | "field_with" => {
                    let mut attribute = ir::Attribute {
                        name: snake(&m.text_of("name")),
                        ..Default::default()
                    };
                    if m.id == "field_with" {
                        self.attribute_options(&m)?.onto(&mut attribute);
                    }
                    let shape = shape_of(&m.text_of("type"));
                    shape.apply(&mut attribute);
                    let Some(vo) = st.agg.value_objects.get_mut(index) else { continue };
                    st.vo_types.push((
                        index,
                        vo.attributes.len(),
                        TypeUse {
                            line: m.line,
                            col: m.col_of("type"),
                            reference: shape.relationship.is_some(),
                            words: shape.words,
                        },
                    ));
                    vo.attributes.push(attribute);
                }
                "field_rule" => {
                    let cond = self.condition(&m)?;
                    checks.extend(cond.field);
                    if let Some(vo) = st.agg.value_objects.get_mut(index) {
                        vo.invariants.push(ir::Given {
                            description: Some(m.text_of("description")),
                            canonical: cond.canonical,
                        });
                    }
                }
                _ => return Err(self.unmeant(&m)),
            }
        }
        let names: Vec<String> = st
            .agg
            .value_objects
            .get(index)
            .map(|vo| vo.attributes.iter().map(|a| a.name.clone()).collect())
            .unwrap_or_default();
        checks
            .iter()
            .find(|check| !names.contains(&check.name))
            .map_or(Ok(()), |unknown| Err(self.unknown_field(unknown, &names)))
    }

    fn lifecycle(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        if st.lifecycle.is_some() {
            return Err(self.error(header.line, header.base_col, "an aggregate has one lifecycle; this is a second"));
        }
        let mut spec = LifecycleSpec {
            field: snake(&header.text_of("field")),
            default: header.text_of("state"),
            transitions: Vec::new(),
            marks: Vec::new(),
        };
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Lifecycle", false)? {
            let Step::Phrase(m) = step else { continue };
            if m.id == "marks" {
                spec.marks.push((m.text_of("mark"), m.capture("states").items));
                continue;
            }
            if m.id != "transition" {
                return Err(self.unmeant(&m));
            }
            self.same_owner(&m, "owner", st)?;
            spec.transitions.push(Transition {
                line: m.line,
                col: m.col_of("command"),
                command: camel(&m.text_of("command")),
                from: m.text_of("from"),
                to: m.text_of("to"),
            });
        }
        st.lifecycle = Some(spec);
        Ok(())
    }

    fn command(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        let mut spec = CommandSpec {
            name: camel(&header.text_of("name")),
            role: None,
            roles: Vec::new(),
            goal: None,
            references: None,
            args: Vec::new(),
            takes: Vec::new(),
            givens: Vec::new(),
            ensures: Vec::new(),
            from: None,
            changes: Vec::new(),
            emits: Vec::new(),
        };
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Command", false)? {
            let Step::Phrase(m) = step else { continue };
            match m.id {
                "goal" => spec.goal = Some(m.text_of("goal")),
                "role" => {
                    let roles = self.roles_of(&m)?;
                    spec.role = roles.first().cloned();
                    if roles.len() > 1 {
                        spec.roles = roles;
                    }
                }
                "acts_on" => {
                    self.same_owner(&m, "owner", st)?;
                    spec.references = Some(st.agg.name.clone());
                }
                "arguments" => spec.args.extend(field_uses(&m, "names")),
                "takes" => spec.takes.extend(self.attribute_lines(&m)?),
                "from_states" => {
                    let mut states = m.capture("states").items;
                    spec.from = Some(if states.len() == 1 {
                        ir::CommandFrom::Single(states.remove(0))
                    } else {
                        ir::CommandFrom::Multiple(states)
                    });
                }
                "ensures" => {
                    let cond = self.condition(&m)?;
                    spec.ensures.push(ir::Given {
                        description: Some(m.text_of("description")),
                        canonical: cond.canonical,
                    });
                }
                "announces" => spec.emits.push(m.text_of("event")),
                "given" => {
                    let cond = self.condition(&m)?;
                    st.checks.extend(cond.field);
                    spec.givens.push(ir::Given {
                        description: Some(m.text_of("description")),
                        canonical: cond.canonical,
                    });
                }
                _ => match self.changes_of(&m)? {
                    Some(changes) => spec.changes.extend(changes),
                    None => return Err(self.unmeant(&m)),
                },
            }
        }
        st.commands.push(spec);
        Ok(())
    }

    /// The roles a `Who:` line names: `Editor`, or `Customer or Sales Rep` for any one of several.
    fn roles_of(&self, m: &Matched) -> ParseResult<Vec<String>> {
        let col = m.col_of("role");
        let mut roles: Vec<String> = Vec::new();
        let mut current: Vec<String> = Vec::new();
        for word in m.text_of("role").split_whitespace() {
            if !word.eq_ignore_ascii_case("or") {
                current.push(word.to_string());
            } else if current.is_empty() {
                return Err(self.error(m.line, col, "an 'or' needs a role before it"));
            } else {
                roles.push(current.join(" "));
                current.clear();
            }
        }
        if current.is_empty() {
            return Err(self.error(m.line, col, "an 'or' needs a role after it"));
        }
        roles.push(current.join(" "));
        let mut distinct = roles.clone();
        distinct.sort();
        distinct.dedup();
        if distinct.len() != roles.len() {
            return Err(self.error(m.line, col, "a role is named twice; name each once"));
        }
        Ok(roles)
    }

    /// Reads the condition a rule, a given or a where carries in its `condition` slot.
    pub(super) fn condition(&self, m: &Matched) -> ParseResult<Cond> {
        let text = m.text_of("condition");
        let base = m.col_of("condition");
        match self.match_text("Condition", &text, base) {
            Ok((phrase, found)) => {
                let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
                if phrase.row.id == "expression" {
                    return Ok(Cond {
                        canonical: crate::canonical::apply(&slot("code").value),
                        field: None,
                        value: None,
                    });
                }
                let field = FieldUse {
                    name: snake(&slot("field").value),
                    line: m.line,
                    col: column(base, &text, slot("field").offset),
                };
                let (canonical, value) = match phrase.row.id {
                    "not_empty" => (format!("!{}.to_s.empty?", field.name), None),
                    "at_least" => (format!("{} >= {}", field.name, slot("n").value), None),
                    "equals" => {
                        let value = slot("value").value;
                        (format!("{} == \"{value}\"", field.name), Some(value))
                    }
                    other => {
                        return Err(self.error(
                            m.line,
                            base,
                            format!("the condition '{other}' is admitted but the parser does not read it yet"),
                        ));
                    }
                };
                Ok(Cond {
                    canonical: crate::canonical::apply(&canonical),
                    field: Some(field),
                    value,
                })
            }
            Err(unmatched) => Err(self
                .error(
                    m.line,
                    unmatched.column,
                    format!("this is not a condition I know: \"{text}\""),
                )
                .with_expected(unmatched.suggestions)),
        }
    }

    fn unknown_field(&self, field: &FieldUse, in_scope: &[String]) -> Diagnostic {
        let known: Vec<String> = in_scope.iter().map(|name| spoken(name)).collect();
        self.error(
            field.line,
            field.col,
            format!(
                "'{}' is not a field here. The fields in scope are: {}",
                spoken(&field.name),
                known.join(", ")
            ),
        )
    }

    /// Resolves the names the aggregate's blocks used, now that all of them are read.
    fn finish(&self, mut st: AggState, header: &Matched) -> ParseResult<ir::Aggregate> {
        if st.identity.is_none() {
            let noun = spoken(&st.agg.name);
            return Err(self.error(
                header.line,
                header.base_col,
                format!(
                    "the {noun} does not say what identifies it. Add a sentence like `A {noun} is identified by its <field>.`"
                ),
            ));
        }
        let types: Vec<String> = st
            .attr_types
            .iter()
            .map(|used| self.type_named(used, &st.agg))
            .collect::<ParseResult<_>>()?;
        for (attribute, resolved) in st.agg.attributes.iter_mut().zip(types) {
            attribute.type_name = resolved;
        }
        for (index, at, used) in &st.vo_types {
            let resolved = self.type_named(used, &st.agg)?;
            if let Some(attribute) = st
                .agg
                .value_objects
                .get_mut(*index)
                .and_then(|vo| vo.attributes.get_mut(*at))
            {
                attribute.type_name = resolved;
            }
        }
        if let Some(found) = &st.identity {
            for field in &found.fields {
                let paths = identity::resolve_identity_field(
                    self.file,
                    found.line,
                    &st.agg.name,
                    field,
                    &[self.outer.clone(), st.agg.value_objects.clone()].concat(),
                    &st.agg.attributes,
                )
                .map_err(|refused| Diagnostic::new(self.file, found.line, refused.message).with_column(found.col))?;
                st.agg.identified_by.extend(paths);
            }
        }
        for (at, args) in std::mem::take(&mut st.query_args) {
            let mut typed = Vec::new();
            for (mut attribute, used) in args {
                attribute.type_name = self.type_named(&used, &st.agg)?;
                typed.push(attribute);
            }
            if let Some(query) = st.agg.queries.get_mut(at) {
                query.attributes = typed;
            }
        }
        let commands = self.commands_of(&mut st)?;
        st.agg.commands = commands;
        self.lifecycle_of(&mut st)?;
        let mut in_scope: Vec<String> = st.agg.attributes.iter().map(|a| a.name.clone()).collect();
        in_scope.extend(st.agg.projected_fields.iter().map(|field| field.name.clone()));
        if let Some(lifecycle) = &st.agg.lifecycle {
            in_scope.push(lifecycle.field.clone());
        }
        for check in &st.checks {
            if !in_scope.contains(&check.name) {
                return Err(self.unknown_field(check, &in_scope));
            }
        }
        Ok(st.agg)
    }

    fn type_named(&self, used: &TypeUse, agg: &ir::Aggregate) -> ParseResult<String> {
        if used.reference {
            return Ok(format!("Reference<{}>", camel(&used.words)));
        }
        if let Some(found) = scalar(&used.words) {
            return Ok(found.to_string());
        }
        let name = camel(&used.words);
        if agg.value_objects.iter().any(|vo| vo.name == name) || self.types.contains(&name) {
            return Ok(name);
        }
        let mut known: Vec<String> = vec![SCALARS.to_string()];
        known.extend(agg.value_objects.iter().map(|vo| spoken(&vo.name)));
        Err(self.error(
            used.line,
            used.col,
            format!(
                "I don't know a type called '{}'. The types here are: {}",
                used.words,
                known.join(", ")
            ),
        ))
    }

    fn commands_of(&self, st: &mut AggState) -> ParseResult<Vec<ir::Command>> {
        let mut commands = Vec::new();
        for spec in std::mem::take(&mut st.commands) {
            let mut command = ir::Command {
                name: spec.name.clone(),
                role: spec.role,
                roles: spec.roles,
                goal: spec.goal,
                references: spec.references,
                givens: spec.givens,
                ensures: spec.ensures,
                from: spec.from,
                emits: spec.emits,
                ..Default::default()
            };
            let fields: Vec<String> = st.agg.attributes.iter().map(|a| a.name.clone()).collect();
            let mut given: Vec<String> = Vec::new();
            for arg in &spec.args {
                let (name, optional) = optional_argument(&arg.name, &fields);
                let Some(attribute) = st.agg.attributes.iter().find(|a| a.name == name) else {
                    return Err(self.unknown_field(arg, &fields));
                };
                command.attributes.push(ir::Attribute {
                    name: attribute.name.clone(),
                    type_name: attribute.type_name.clone(),
                    list: attribute.list,
                    optional,
                    ..Default::default()
                });
                given.push(name);
            }
            for (mut attribute, used) in spec.takes {
                attribute.type_name = self.type_named(&used, &st.agg)?;
                given.push(attribute.name.clone());
                command.attributes.push(attribute);
            }
            let mut state_fields = fields.clone();
            state_fields.extend(st.lifecycle.as_ref().map(|lifecycle| lifecycle.field.clone()));
            command.mutations = self.mutations_of(&spec.name, spec.changes, &given, &state_fields)?;
            commands.push(command);
        }
        Ok(commands)
    }

    fn lifecycle_of(&self, st: &mut AggState) -> ParseResult<()> {
        let Some(spec) = st.lifecycle.take() else {
            return Ok(());
        };
        let known: Vec<String> = st.agg.commands.iter().map(|c| c.name.clone()).collect();
        let mut lifecycle = ir::Lifecycle {
            field: spec.field,
            default: spec.default,
            marks: spec.marks,
            ..Default::default()
        };
        for t in spec.transitions {
            if !known.contains(&t.command) {
                let shown: Vec<String> = known.iter().map(|name| spoken(name)).collect();
                return Err(self.error(
                    t.line,
                    t.col,
                    format!(
                        "'{}' moves the page between states, but no command by that name is declared. Commands here: {}",
                        spoken(&t.command),
                        shown.join(", ")
                    ),
                ));
            }
            lifecycle.transitions.push(ir::StateTransitionRow {
                command: t.command,
                to_state: t.to,
                from_state: Some(t.from),
            });
        }
        st.agg.lifecycle = Some(lifecycle);
        Ok(())
    }
}

/// An argument as written (`optional description` -> `description`, optional) unless a field of the
/// whole name exists.
fn optional_argument(written: &str, fields: &[String]) -> (String, bool) {
    if fields.iter().any(|field| field == written) {
        return (written.to_string(), false);
    }
    written
        .strip_prefix("optional_")
        .map_or_else(|| (written.to_string(), false), |name| (name.to_string(), true))
}

impl ir::Bluebook {
    /// Adds the capability row a `key is Verb` line under `It provides …:` says.
    fn provisions_push(&mut self, capability: &str, row: &Matched) {
        self.provides.push(ir::Provision {
            capability: capability.to_string(),
            key: row.text_of("key"),
            verb: row.text_of("verb"),
        });
    }
}

/// What the words of a type say beyond the type: a list, or a link to another aggregate.
struct Shape {
    /// The words once the form is taken off: `list of tag` -> `tag`.
    words: String,
    list: bool,
    /// `reference_to` for `reference to …` and `has_many` for `has many …`.
    relationship: Option<&'static str>,
}

impl Shape {
    fn apply(&self, attribute: &mut ir::Attribute) {
        attribute.list = self.list;
        attribute.relationship = self.relationship.map(str::to_string);
    }
}

/// Reads `list of …`, `reference to …` and `has many …` off the front of a type phrase.
fn shape_of(words: &str) -> Shape {
    let forms: [(&str, bool, Option<&'static str>); 3] = [
        ("list of ", true, None),
        ("reference to ", false, Some("reference_to")),
        ("has many ", true, Some("has_many")),
    ];
    for (prefix, list, relationship) in forms {
        if let Some(inner) = words.strip_prefix(prefix) {
            return Shape { words: inner.trim().to_string(), list, relationship };
        }
    }
    Shape { words: words.to_string(), list: false, relationship: None }
}

pub(super) fn field_uses(m: &Matched, slot: &str) -> Vec<FieldUse> {
    let capture = m.capture(slot);
    let col = m.col_of(slot);
    capture
        .items
        .iter()
        .map(|item| FieldUse {
            name: snake(item),
            line: m.line,
            col,
        })
        .collect()
}
