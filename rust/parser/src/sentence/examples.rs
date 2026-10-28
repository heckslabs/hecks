//! Examples: a `.examples` file, written as sentences, compiled to the `.behaviors` text that
//! runs it against the domain it is about.
//!
//! An example says who does what and what follows, in the domain's own words. Every name in it is
//! checked against the parsed bluebook, so an example can only mean something the domain declares:
//! a person's role, a command and the fields it takes, a lifecycle state, an event, a rule's own
//! sentence. What does not resolve is refused with what would have.

// reason: this builds a few kilobytes of text a line at a time; an allocation per line costs
// nothing and `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use super::command_step;
use super::names::{camel, spoken};
use super::outside::{self, Action};
use super::values::{self, Target};
use super::{column, read_lines, Grammar, Match, Matched, Parser, Scope, Step};
use crate::diag::ParseResult;
use crate::ir;
use crate::render_ruby::string as ruby_string;

/// Compiles an examples file to `.behaviors` text.
///
/// `bluebook` is the parsed domain the examples are about; `bluebook_files` are the absolute paths
/// of its files, which the suite boots.
pub fn compile(
    declaration: &ir::Bluebook,
    bluebook_files: &[String],
    path: &str,
    source: &str,
) -> ParseResult<String> {
    let grammar = Grammar::load()?;
    let lines = read_lines(path, source)?;
    let mut parser = Parser::new(path, &grammar, lines);
    let tests = parser.examples(declaration)?;
    Ok(behaviors_text(declaration, bluebook_files, path, &tests))
}

/// A person introduced under `Background:`.
struct Person {
    name: String,
    role: String,
}

/// One line of an example, before its words are read.
struct Raw {
    keyword: Keyword,
    text: String,
    line: usize,
    col: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Keyword {
    Given,
    When,
    Then,
    And,
}

/// The `Where:` table of an example: one test per row.
struct Table {
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

/// A step read and resolved against the domain.
struct Dispatch<'c> {
    role: Option<String>,
    aggregate: &'c ir::Aggregate,
    action: Action<'c>,
    /// The fields that name the record the command acts on, for a step that acts on `it`.
    identity: Vec<(String, String)>,
    args: Vec<(String, String)>,
    tries: bool,
    line: usize,
    col: usize,
}

/// What a step says about the command it names, ready to check against that command.
#[derive(Clone, Copy)]
struct StepForm<'a> {
    who: &'a str,
    aggregate: &'a ir::Aggregate,
    command: &'a ir::Command,
    object: Option<&'a command_step::Object>,
    acts_on_it: bool,
}

/// A record created earlier in the example, and the fields that identify it.
struct Created {
    aggregate: String,
    identity: Vec<(String, String)>,
}

/// What an example expects of its tested step.
#[derive(Default)]
struct Expect {
    state: Option<(String, String)>,
    /// Fields of the record the step leaves, or of the one row a query finds, and the Ruby text
    /// of each value.
    fields: Vec<(String, String)>,
    /// How many rows a query finds.
    count: Option<usize>,
    emits: Vec<String>,
    refused: Option<String>,
}

/// What a compiled test exercises, and how the behaviors file names it.
enum Subject {
    /// `tests "Purchase", on: "Order"`.
    Command,
    /// `tests "Pizzas::Order.PaymentGateway.Receive"`, the fact going to the record `to`.
    Arrival { to: String },
    /// `tests "Available", on: "Order", kind: :query`.
    Query,
}

/// One compiled test.
struct TestOut {
    title: String,
    aggregate: String,
    command: String,
    subject: Subject,
    role: Option<String>,
    setups: Vec<SetupOut>,
    input: Vec<(String, String)>,
    expect: Expect,
}

struct SetupOut {
    verb: String,
    role: Option<String>,
    args: Vec<(String, String)>,
}

impl Parser<'_> {
    /// Reads the whole examples file.
    fn examples(&mut self, declaration: &ir::Bluebook) -> ParseResult<Vec<TestOut>> {
        let mut top = Scope::top();
        let Some(Step::Phrase(header)) = self.step(&mut top, "ExamplesFile", false)? else {
            return Err(self.error(
                1,
                1,
                "this file is empty; it starts with `Examples for: <bluebook>`",
            ));
        };
        let named = camel(&header.text_of("name"));
        if named != declaration.name {
            return Err(self.error(
                header.line,
                header.col_of("name"),
                format!(
                    "these examples are about '{named}', but the bluebook is '{}'",
                    declaration.name
                ),
            ));
        }
        let mut people: Vec<Person> = Vec::new();
        let mut tests = Vec::new();
        let mut body = Scope::top();
        body.first = false;
        while let Some(step) = self.step(&mut body, "Examples", false)? {
            let Step::Phrase(m) = step else { continue };
            match m.id {
                "background" => self.background(&m, &mut people)?,
                "example" => tests.extend(self.example(&m, declaration, &people)?),
                _ => return Err(self.unmeant(&m)),
            }
        }
        if tests.is_empty() {
            return Err(self.error(header.line, 1, "these examples hold no `Example:`"));
        }
        Ok(tests)
    }

    fn background(&mut self, header: &Matched, people: &mut Vec<Person>) -> ParseResult<()> {
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Background", false)? {
            let Step::Phrase(m) = step else { continue };
            let name = m.text_of("person");
            if people.iter().any(|p| p.name.eq_ignore_ascii_case(&name)) {
                return Err(self.error(
                    m.line,
                    m.col_of("person"),
                    format!("{name} is introduced twice"),
                ));
            }
            people.push(Person {
                name,
                role: m.text_of("role"),
            });
        }
        Ok(())
    }

    /// Reads one `Example:` and compiles it, once per row of its `Where:` table.
    fn example(
        &mut self,
        header: &Matched,
        declaration: &ir::Bluebook,
        people: &[Person],
    ) -> ParseResult<Vec<TestOut>> {
        let title = header.text_of("title");
        let mut lines: Vec<Raw> = Vec::new();
        let mut table: Option<Table> = None;
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Example", false)? {
            let Step::Phrase(m) = step else { continue };
            let (keyword, slot) = match m.id {
                "given_step" => (Keyword::Given, "step"),
                "when_step" => (Keyword::When, "step"),
                "then_outcome" => (Keyword::Then, "outcome"),
                "and_line" => (Keyword::And, "line"),
                "where_table" => {
                    table = Some(self.table(&m)?);
                    continue;
                }
                _ => return Err(self.unmeant(&m)),
            };
            lines.push(Raw {
                keyword,
                text: m.text_of(slot),
                line: m.line,
                col: m.col_of(slot),
            });
        }
        let rows = table.map_or_else(
            || vec![Vec::new()],
            |t| {
                t.rows
                    .iter()
                    .map(|row| t.columns.iter().cloned().zip(row.iter().cloned()).collect())
                    .collect()
            },
        );
        let several = rows.len() > 1
            || rows
                .first()
                .is_some_and(|row: &Vec<(String, String)>| !row.is_empty());
        let mut tests = Vec::new();
        for row in &rows {
            let mut named = substitute(&title, row);
            if several && !title.contains('<') {
                if let Some((_, first)) = row.first() {
                    named = format!("{named} ({first})");
                }
            }
            let filled: Vec<Raw> = lines
                .iter()
                .map(|raw| Raw {
                    keyword: raw.keyword,
                    text: substitute(&raw.text, row),
                    line: raw.line,
                    col: raw.col,
                })
                .collect();
            tests.push(self.interpret(declaration, people, &named, header, &filled)?);
        }
        Ok(tests)
    }

    /// Reads the `| a | b |` lines under a `Where:` header.
    fn table(&mut self, header: &Matched) -> ParseResult<Table> {
        let mut rows: Vec<Vec<String>> = Vec::new();
        while let Some(line) = self.lines.get(self.pos).cloned() {
            if line.indent <= header.indent {
                break;
            }
            if !(line.text.starts_with('|') && line.text.ends_with('|')) {
                return Err(self.error(
                    line.number,
                    line.indent + 1,
                    "a Where table is made of `| cell | cell |` lines",
                ));
            }
            rows.push(
                line.text
                    .trim_matches('|')
                    .split('|')
                    .map(|cell| cell.trim().to_string())
                    .collect(),
            );
            self.pos += 1;
        }
        let mut rows = rows.into_iter();
        let Some(columns) = rows.next() else {
            return Err(self.error(
                header.line,
                header.base_col,
                "this Where has no table under it",
            ));
        };
        let rows: Vec<Vec<String>> = rows.collect();
        if let Some(bad) = rows.iter().find(|row| row.len() != columns.len()) {
            return Err(self.error(
                header.line,
                header.base_col,
                format!(
                    "a row has {} cells, but the table has {} columns: {}",
                    bad.len(),
                    columns.len(),
                    columns.join(", ")
                ),
            ));
        }
        if rows.is_empty() {
            return Err(self.error(
                header.line,
                header.base_col,
                "this Where has columns but no rows",
            ));
        }
        Ok(Table { columns, rows })
    }

    /// Turns one example's lines into a test.
    fn interpret<'c>(
        &self,
        declaration: &'c ir::Bluebook,
        people: &[Person],
        title: &str,
        header: &Matched,
        lines: &[Raw],
    ) -> ParseResult<TestOut> {
        let mut created: Vec<Created> = Vec::new();
        let mut setups: Vec<Dispatch<'c>> = Vec::new();
        let mut tested: Option<Dispatch<'c>> = None;
        let mut outcomes: Vec<&Raw> = Vec::new();
        let mut section = Keyword::Given;
        for raw in lines {
            let current = if raw.keyword == Keyword::And {
                section
            } else {
                raw.keyword
            };
            section = current;
            match current {
                Keyword::Given | Keyword::And => {
                    let step = self.dispatch(declaration, people, raw, &mut created)?;
                    if step.tries {
                        return Err(self.error(
                            raw.line,
                            raw.col,
                            "a Given step has to succeed; put the step that is refused under When",
                        ));
                    }
                    if step.action.command().is_none() {
                        return Err(self.error(
                            raw.line,
                            raw.col,
                            "a Given step is a command a person runs; a port announcing a fact, or a query, goes under When",
                        ));
                    }
                    setups.push(step);
                }
                Keyword::When => {
                    if tested.is_some() {
                        return Err(self.error(
                            raw.line,
                            raw.col,
                            "an example proves one action; this is a second When",
                        ));
                    }
                    tested = Some(self.dispatch(declaration, people, raw, &mut created)?);
                }
                Keyword::Then => outcomes.push(raw),
            }
        }
        let Some(tested) = tested else {
            return Err(self.error(
                header.line,
                header.base_col,
                "this example has no `When` step",
            ));
        };
        let mut expect = Expect::default();
        for raw in outcomes {
            self.outcome(declaration, raw, &tested, &mut expect)?;
        }
        self.consistent(&tested, &expect)?;
        let (command, subject, input) = tested_parts(declaration, &tested);
        Ok(TestOut {
            title: title.to_string(),
            aggregate: tested.aggregate.name.clone(),
            command,
            subject,
            role: tested.role,
            setups: setups
                .into_iter()
                .map(|step| SetupOut {
                    verb: format!(
                        "{}::{}.{}",
                        declaration.name,
                        step.aggregate.name,
                        step.action
                            .command()
                            .map_or_else(String::new, |c| c.name.clone())
                    ),
                    role: step.role,
                    args: step.identity.into_iter().chain(step.args).collect(),
                })
                .collect(),
            input,
            expect,
        })
    }

    /// Reads one step: who does what, to what, with which values.
    fn dispatch<'c>(
        &self,
        declaration: &'c ir::Bluebook,
        people: &[Person],
        raw: &Raw,
        created: &mut Vec<Created>,
    ) -> ParseResult<Dispatch<'c>> {
        let (phrase, found) = self
            .match_text("Step", &raw.text, raw.col)
            .map_err(|unmatched| {
                self.error(
                    raw.line,
                    unmatched.column,
                    format!("this is not a step I know: \"{}\"", raw.text),
                )
                .with_expected(unmatched.suggestions)
            })?;
        let id = phrase.row.id;
        let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
        let at = |name: &str| column(raw.col, &raw.text, slot(name).offset);

        let who = slot("who").value;
        if id.starts_with("step_runs") {
            return self.query_step(declaration, people, raw, &found, id);
        }
        if let Some(resolved) = outside::arrival(declaration, &who, &slot("verb").value) {
            return self.arrival_step(raw, &found, id, resolved, created);
        }
        let role = self.role_of(people, &who, raw.line, at("who"))?;
        let verb = slot("verb").value;
        let object = command_step::Object::of(&slot("noun").value);
        let (aggregate, command) =
            self.find_command(declaration, &verb, object.as_ref(), raw.line, at("verb"))?;

        let acts_on_it = id.contains("acts") || object.as_ref().is_some_and(|o| o.to_it);
        let form = StepForm {
            who: &who,
            aggregate,
            command,
            object: object.as_ref(),
            acts_on_it,
        };
        self.check_form(&form, raw.line, at("verb"), at("noun"))?;

        let args = if id.ends_with("bare") {
            Vec::new()
        } else {
            let target = Target::of_command(aggregate, command);
            values::read(self, &target, &slot("args").value, raw.line, at("args"))?
        };
        let identity = if acts_on_it {
            self.record_it(created, aggregate, raw)?
        } else {
            let identity = identity_of(aggregate, &args, self, raw)?;
            created.push(Created {
                aggregate: aggregate.name.clone(),
                identity,
            });
            Vec::new()
        };
        Ok(Dispatch {
            role: Some(role),
            aggregate,
            action: Action::Command(command),
            identity,
            args,
            tries: id.starts_with("step_tries"),
            line: raw.line,
            col: raw.col,
        })
    }

    /// The fields that identify the record `it` means: the last one made of this aggregate.
    fn record_it(
        &self,
        created: &[Created],
        aggregate: &ir::Aggregate,
        raw: &Raw,
    ) -> ParseResult<Vec<(String, String)>> {
        created
            .iter()
            .rev()
            .find(|record| record.aggregate == aggregate.name)
            .map(|record| record.identity.clone())
            .ok_or_else(|| {
                self.error(
                    raw.line,
                    raw.col,
                    format!(
                        "there is no {} yet for `it` to mean; create one in an earlier step",
                        spoken(&aggregate.name)
                    ),
                )
            })
    }

    /// A step in which a port announces a fact about the record made earlier: `the payment
    /// gateway receives it with customer name "Chris" and amount 1200 cents`.
    fn arrival_step<'c>(
        &self,
        raw: &Raw,
        found: &Match,
        id: &str,
        resolved: Result<outside::Arrival<'c>, Vec<String>>,
        created: &[Created],
    ) -> ParseResult<Dispatch<'c>> {
        let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
        let at = |name: &str| column(raw.col, &raw.text, slot(name).offset);
        let (who, verb) = (slot("who").value, slot("verb").value);
        let (aggregate, port, operation) = resolved.map_err(|wordings| {
            self.error(
                raw.line,
                at("verb"),
                format!(
                    "{who} does not '{verb}'. A step can say: {}",
                    wordings.join(", ")
                ),
            )
        })?;
        let right = format!(
            "{who} {} it",
            super::command_step::third_person(&spoken(&operation.name))
        );
        if id.starts_with("step_tries") {
            return Err(self.error(
                raw.line,
                at("who"),
                "a port only announces a fact, so it is never refused; what the bluebook does with it is decided by the rules of the command a policy runs",
            ));
        }
        if !id.contains("acts") {
            return Err(self.error(
                raw.line,
                at("verb"),
                format!("a port announces a fact about a record that exists; write `{right}`"),
            ));
        }
        let target = Target {
            aggregate,
            subject: format!("{} {}", spoken(&port.name), spoken(&operation.name)),
            attributes: &operation.attributes,
            partial: false,
        };
        let text = if id.ends_with("bare") {
            String::new()
        } else {
            slot("args").value
        };
        let args = values::read(self, &target, &text, raw.line, at("args"))?;
        Ok(Dispatch {
            role: None,
            aggregate,
            action: Action::Arrival { port, operation },
            identity: self.record_it(created, aggregate, raw)?,
            args,
            tries: false,
            line: raw.line,
            col: raw.col,
        })
    }

    /// A step that runs a query: `Chris runs the costing less than query with ceiling 1000 cents`.
    fn query_step<'c>(
        &self,
        declaration: &'c ir::Bluebook,
        people: &[Person],
        raw: &Raw,
        found: &Match,
        id: &str,
    ) -> ParseResult<Dispatch<'c>> {
        let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
        let at = |name: &str| column(raw.col, &raw.text, slot(name).offset);
        self.role_of(people, &slot("who").value, raw.line, at("who"))?;
        let (aggregate, query) =
            outside::query_named(declaration, &slot("query").value).map_err(|wordings| {
                self.error(
                    raw.line,
                    at("query"),
                    format!(
                        "'{}' is not a query here. A step can say: {}",
                        slot("query").value,
                        wordings.join(", ")
                    ),
                )
            })?;
        let target = Target {
            aggregate,
            subject: spoken(&query.name),
            attributes: &query.attributes,
            partial: false,
        };
        let text = if id.ends_with("with") {
            slot("args").value
        } else {
            String::new()
        };
        let args = values::read(self, &target, &text, raw.line, at("args"))?;
        Ok(Dispatch {
            role: None,
            aggregate,
            action: Action::Query(query),
            identity: Vec::new(),
            args,
            tries: false,
            line: raw.line,
            col: raw.col,
        })
    }

    /// The role a person holds, or `the Editor` named outright.
    fn role_of(
        &self,
        people: &[Person],
        who: &str,
        line: usize,
        col: usize,
    ) -> ParseResult<String> {
        if let Some(person) = people.iter().find(|p| p.name.eq_ignore_ascii_case(who)) {
            return Ok(person.role.clone());
        }
        if let Some(role) = who
            .strip_prefix("the ")
            .or_else(|| who.strip_prefix("The "))
        {
            return Ok(role.to_string());
        }
        let known: Vec<String> = people
            .iter()
            .map(|p| format!("{} ({})", p.name, p.role))
            .collect();
        Err(self.error(
            line,
            col,
            format!(
                "I don't know who '{who}' is. Introduce them under Background, like `Dana is an Editor`, or write `the <role>`. Known: {}",
                if known.is_empty() { "nobody".to_string() } else { known.join(", ") }
            ),
        ))
    }

    /// The command a verb and object name: `drafts a page` is `Draft`, `adds a topping to it` is
    /// `AddTopping`.
    fn find_command<'c>(
        &self,
        declaration: &'c ir::Bluebook,
        verb: &str,
        object: Option<&command_step::Object>,
        line: usize,
        col: usize,
    ) -> ParseResult<command_step::Found<'c>> {
        command_step::find(declaration, verb, object).map_err(|miss| {
            let said = command_step::as_said(verb, object);
            match miss {
                command_step::Miss::Nothing(wordings) => self.error(
                    line,
                    col,
                    format!(
                        "'{said}' is not a command here. A step can say: {}",
                        wordings.join(", ")
                    ),
                ),
                command_step::Miss::Several(names) => self.error(
                    line,
                    col,
                    format!(
                        "more than one command reads as '{said}': {}. A step cannot say which \
                         aggregate, so give them names whose words differ",
                        names.join(", ")
                    ),
                ),
            }
        })
    }

    /// Checks a step's form against the command it names: a command that makes a record is not
    /// written as acting on `it`, and one that acts on a record is.
    fn check_form(
        &self,
        form: &StepForm<'_>,
        line: usize,
        verb_col: usize,
        noun_col: usize,
    ) -> ParseResult<()> {
        let StepForm {
            who,
            aggregate,
            command,
            ..
        } = *form;
        let right = command_step::wording(aggregate, command);
        let says_to_it = form.object.is_some_and(|o| o.to_it);
        let makes = command.references.is_none();
        let fault = if says_to_it && !command_step::is_multi_word(command) {
            Some(format!(
                "`to it` goes only with a command named by several words; write `{who} {right}`"
            ))
        } else if form.acts_on_it && makes {
            Some(format!(
                "{} makes {} rather than acting on one that exists; write `{who} {right} with …`",
                spoken(&command.name),
                command_step::with_article(&spoken(&aggregate.name))
            ))
        } else if !form.acts_on_it && !makes {
            Some(format!(
                "{} acts on {} that exists; write `{who} {right}`",
                spoken(&command.name),
                command_step::with_article(&spoken(&aggregate.name))
            ))
        } else {
            None
        };
        if let Some(fault) = fault {
            return Err(self.error(line, verb_col, fault));
        }
        self.check_noun(form, noun_col, line)
    }

    /// A one-word command that makes a record is written with the record's own name.
    fn check_noun(&self, form: &StepForm<'_>, col: usize, line: usize) -> ParseResult<()> {
        let StepForm {
            aggregate,
            command,
            object,
            ..
        } = *form;
        let Some(object) = object else { return Ok(()) };
        if form.acts_on_it
            || command_step::is_multi_word(command)
            || object.words == spoken(&aggregate.name)
        {
            return Ok(());
        }
        Err(self.error(
            line,
            col,
            format!(
                "{} makes {}, not {}",
                spoken(&command.name),
                command_step::with_article(&spoken(&aggregate.name)),
                command_step::with_article(&object.words)
            ),
        ))
    }

    /// Reads one `Then` or `And` line after the tested step.
    fn outcome(
        &self,
        declaration: &ir::Bluebook,
        raw: &Raw,
        tested: &Dispatch<'_>,
        expect: &mut Expect,
    ) -> ParseResult<()> {
        let text = raw.text.strip_suffix('.').unwrap_or(&raw.text);
        let (phrase, found) = self
            .match_text("Outcome", text, raw.col)
            .map_err(|unmatched| {
                self.error(
                    raw.line,
                    unmatched.column,
                    format!("this is not an outcome I know: \"{}\"", raw.text),
                )
                .with_expected(unmatched.suggestions)
            })?;
        let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
        let at = |name: &str| column(raw.col, text, slot(name).offset);
        match phrase.row.id {
            "outcome_state" => {
                let noun = slot("noun").value.to_lowercase();
                if noun != spoken(&tested.aggregate.name) {
                    return Err(self.error(
                        raw.line,
                        at("noun"),
                        format!(
                            "the example is about a {}, not a {noun}",
                            spoken(&tested.aggregate.name)
                        ),
                    ));
                }
                let Some(lifecycle) = &tested.aggregate.lifecycle else {
                    return Err(self.error(raw.line, raw.col, format!("a {noun} has no states")));
                };
                let state = slot("state").value;
                let mut states = vec![lifecycle.default.clone()];
                for t in &lifecycle.transitions {
                    states.extend(t.from_state.iter().cloned());
                    states.push(t.to_state.clone());
                }
                if !states.contains(&state) {
                    states.dedup();
                    return Err(self.error(
                        raw.line,
                        at("state"),
                        format!(
                            "a {noun} is never {state}. Its states are: {}",
                            unique(&states).join(", ")
                        ),
                    ));
                }
                expect.state = Some((lifecycle.field.clone(), state));
            }
            "outcome_announced" => {
                let event = slot("event").value;
                let announced = announced_by(declaration, &tested.action);
                if !announced.contains(&event) {
                    return Err(self.error(
                        raw.line,
                        at("event"),
                        format!(
                            "{} announces {}, not {event}",
                            tested.action.spoken(),
                            if announced.is_empty() {
                                "nothing".to_string()
                            } else {
                                announced.join(", ")
                            }
                        ),
                    ));
                }
                expect.emits.push(event);
            }
            "outcome_found" | "outcome_none_found" => {
                let number = found.get("count").map_or(Ok(0), |c| {
                    c.value
                        .parse::<usize>()
                        .map_err(|_| self.error(raw.line, at("count"), "a count is a whole number"))
                })?;
                self.outcome_count(raw, at("noun"), &slot("noun").value, number, tested, expect)?;
            }
            "outcome_its" => {
                self.outcome_field(
                    raw,
                    &slot("field").value,
                    &slot("value").value,
                    at("field"),
                    tested,
                    expect,
                )?;
            }
            "outcome_refused_role" => {
                let command = self.refusable(raw, tested)?;
                let named = slot("role").value;
                let declared: Vec<String> = if command.roles.is_empty() {
                    command.role.iter().cloned().collect()
                } else {
                    command.roles.clone()
                };
                let mut said: Vec<&str> = named.split(" or ").map(str::trim).collect();
                let mut held: Vec<&str> = declared.iter().map(String::as_str).collect();
                said.sort_unstable();
                held.sort_unstable();
                if said != held {
                    return Err(self.error(
                        raw.line,
                        at("role"),
                        format!(
                            "{} is run by {}, not by {named}",
                            spoken(&command.name),
                            if declared.is_empty() {
                                "anyone".to_string()
                            } else {
                                declared.join(" or ")
                            }
                        ),
                    ));
                }
                let caller = tested.role.clone().unwrap_or_default();
                expect.refused = Some(format!(
                    "role: {}, and the caller stated {caller}",
                    declared.join(" or ")
                ));
            }
            "outcome_refused" => {
                let command = self.refusable(raw, tested)?;
                let reason = slot("reason").value;
                let reason = reason.strip_suffix('.').unwrap_or(&reason).to_string();
                let rules = rules_of(tested.aggregate, command);
                if !rules.contains(&reason) {
                    return Err(self.error(
                        raw.line,
                        at("reason"),
                        format!(
                            "no rule of {} says \"{reason}\". The rules are: {}",
                            spoken(&command.name),
                            if rules.is_empty() {
                                "none".to_string()
                            } else {
                                rules
                                    .iter()
                                    .map(|r| format!("\"{r}\""))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            }
                        ),
                    ));
                }
                expect.refused = Some(reason);
            }
            _ => {
                return Err(self.error(
                    raw.line,
                    raw.col,
                    format!(
                        "the outcome '{}' is admitted but not read yet",
                        phrase.row.id
                    ),
                ));
            }
        }
        Ok(())
    }

    /// An example that tries something should say why it is refused, and only then.
    fn consistent(&self, tested: &Dispatch<'_>, expect: &Expect) -> ParseResult<()> {
        if tested.tries && expect.refused.is_none() {
            return Err(self.error(tested.line, tested.col, "this step tries to do something; say why it is refused with `Then it is refused because …`"));
        }
        if !tested.tries && expect.refused.is_some() {
            return Err(self.error(
                tested.line,
                tested.col,
                "this example expects a refusal, so the step should read `… tries to …`",
            ));
        }
        if expect.refused.is_some() && expect.has_outcomes() {
            return Err(self.error(
                tested.line,
                tested.col,
                "a refused command changes nothing; an example is either refused or has outcomes",
            ));
        }
        if expect.refused.is_none() && !expect.has_outcomes() {
            return Err(self.error(
                tested.line,
                tested.col,
                "this example proves nothing; add a `Then`",
            ));
        }
        self.fits_action(tested, expect)
    }

    /// An outcome has to be one the step can have: a query finds rows and announces nothing, and
    /// a command or a port leaves a record and announces events.
    fn fits_action(&self, tested: &Dispatch<'_>, expect: &Expect) -> ParseResult<()> {
        let fault = match tested.action {
            Action::Query(_) if !expect.emits.is_empty() => {
                Some("a query announces nothing; say what it finds")
            }
            Action::Command(_) | Action::Arrival { .. } if expect.count.is_some() => {
                Some("only a query finds rows; count them after `runs the … query`")
            }
            Action::Arrival { .. } if expect.state.is_some() || !expect.fields.is_empty() => {
                Some("a port announces a fact; say what is announced, and read the record in an example that runs a command")
            }
            _ => None,
        };
        fault.map_or(Ok(()), |fault| {
            Err(self.error(tested.line, tested.col, fault))
        })
    }

    /// The command of a step that can be refused; a port or a query never is.
    fn refusable<'c>(&self, raw: &Raw, tested: &Dispatch<'c>) -> ParseResult<&'c ir::Command> {
        tested.action.command().ok_or_else(|| {
            self.error(
                raw.line,
                raw.col,
                format!(
                    "{} is never refused; only a command run by a person is",
                    tested.action.spoken()
                ),
            )
        })
    }

    /// `Then 2 orders are found`: how many rows the query finds.
    fn outcome_count(
        &self,
        raw: &Raw,
        col: usize,
        noun: &str,
        number: usize,
        tested: &Dispatch<'_>,
        expect: &mut Expect,
    ) -> ParseResult<()> {
        if !matches!(tested.action, Action::Query(_)) {
            return Err(self.error(raw.line, raw.col, "only a query finds rows"));
        }
        if !outside::names_records(noun, tested.aggregate) {
            return Err(self.error(
                raw.line,
                col,
                format!(
                    "the query finds {}, not {noun}",
                    command_step::with_article(&spoken(&tested.aggregate.name))
                ),
            ));
        }
        expect.count = Some(number);
        Ok(())
    }

    /// `Then its name is "Only One"`, `Then its customer name is not set`: a field of the record a
    /// command leaves, or of the one row a query finds.
    fn outcome_field(
        &self,
        raw: &Raw,
        field: &str,
        value: &str,
        col: usize,
        tested: &Dispatch<'_>,
        expect: &mut Expect,
    ) -> ParseResult<()> {
        let target = Target {
            aggregate: tested.aggregate,
            subject: spoken(&tested.aggregate.name),
            attributes: &tested.aggregate.attributes,
            partial: true,
        };
        let name = values::field_named(&target, field).map_err(|fields| {
            self.error(
                raw.line,
                col,
                format!(
                    "{} has no '{field}'. Its fields are: {}",
                    command_step::with_article(&spoken(&tested.aggregate.name)),
                    fields.join(", ")
                ),
            )
        })?;
        let literal = outside::field_value(value)
            .map_err(|why| self.error(raw.line, col + field.len() + 4, why))?;
        expect.fields.push((name, literal));
        Ok(())
    }
}

/// Every event an action announces, including those announced by commands that policies run in
/// answer to its events, and so on until nothing new follows.
fn announced_by(declaration: &ir::Bluebook, action: &Action<'_>) -> Vec<String> {
    let mut events: Vec<String> = action.first_events();
    let mut grew = true;
    while grew {
        grew = false;
        for policy in &declaration.policies {
            let Some(on) = policy.on_event.as_deref() else {
                continue;
            };
            let event = on.split_once('.').map_or(on, |(_, name)| name);
            let Some(trigger) = policy.trigger_command.as_deref() else {
                continue;
            };
            if !events.iter().any(|known| known == event) {
                continue;
            }
            for aggregate in &declaration.aggregates {
                for next in aggregate
                    .commands
                    .iter()
                    .filter(|c| format!("{}.{}", aggregate.name, c.name) == trigger)
                {
                    for emitted in &next.emits {
                        if !events.contains(emitted) {
                            events.push(emitted.clone());
                            grew = true;
                        }
                    }
                }
            }
        }
    }
    events
}

/// What the behaviors file calls the tested step, how it exercises the domain, and the input it
/// is given.
fn tested_parts(
    declaration: &ir::Bluebook,
    tested: &Dispatch<'_>,
) -> (String, Subject, Vec<(String, String)>) {
    match tested.action {
        Action::Command(command) => {
            let input = tested.identity.iter().chain(tested.args.iter()).cloned();
            (command.name.clone(), Subject::Command, input.collect())
        }
        Action::Query(query) => (query.name.clone(), Subject::Query, tested.args.clone()),
        Action::Arrival { port, operation } => {
            let verb = format!(
                "{}::{}.{}.{}",
                declaration.name, tested.aggregate.name, port.name, operation.name
            );
            let to = bare_identity(&tested.identity);
            (verb, Subject::Arrival { to }, tested.args.clone())
        }
    }
}

/// The identity a port is addressed with: the bare value when one field identifies the record,
/// else the fields as a hash.
fn bare_identity(identity: &[(String, String)]) -> String {
    match identity {
        [(_, value)] => value
            .strip_prefix("{ value: ")
            .and_then(|rest| rest.strip_suffix(" }"))
            .map_or_else(|| value.clone(), str::to_string),
        _ => format!("{{ {} }}", hash_args(identity).trim_start_matches(", ")),
    }
}

/// Every sentence a refusal of this step may give: the command's rules and the value objects'.
fn rules_of(aggregate: &ir::Aggregate, command: &ir::Command) -> Vec<String> {
    let mut rules: Vec<String> = command
        .givens
        .iter()
        .filter_map(|given| given.description.clone())
        .collect();
    for object in &aggregate.value_objects {
        rules.extend(
            object
                .invariants
                .iter()
                .filter_map(|rule| rule.description.clone()),
        );
    }
    rules
}

/// The fields that identify a record a creating step made, in the form the runtime is given them.
fn identity_of(
    aggregate: &ir::Aggregate,
    args: &[(String, String)],
    parser: &Parser<'_>,
    raw: &Raw,
) -> ParseResult<Vec<(String, String)>> {
    let mut names: Vec<&str> = aggregate
        .identified_by
        .iter()
        .map(|path| path.split('.').next().unwrap_or(path))
        .collect();
    names.dedup();
    names
        .into_iter()
        .map(|name| {
            args.iter()
                .find(|(field, _)| field == name)
                .cloned()
                .ok_or_else(|| {
                    parser.error(
                        raw.line,
                        raw.col,
                        format!(
                            "this step does not give the {} that identifies the {}",
                            spoken(name),
                            spoken(&aggregate.name)
                        ),
                    )
                })
        })
        .collect()
}

fn unique(items: &[String]) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for item in items {
        if !seen.contains(item) {
            seen.push(item.clone());
        }
    }
    seen
}

/// Replaces each `<column>` in `text` with the row's cell.
fn substitute(text: &str, row: &[(String, String)]) -> String {
    row.iter().fold(text.to_string(), |acc, (name, cell)| {
        acc.replace(&format!("<{name}>"), cell)
    })
}

/// The `.behaviors` text that runs the compiled tests.
fn behaviors_text(
    declaration: &ir::Bluebook,
    files: &[String],
    path: &str,
    tests: &[TestOut],
) -> String {
    let file = path.rsplit('/').next().unwrap_or(path);
    let mut out = format!(
        "Hecks.behaviors {} do\n",
        ruby_string(&format!("{} examples", declaration.name))
    );
    out.push_str(&format!(
        "  vision {}\n",
        ruby_string(&format!("Examples written as sentences in {file}."))
    ));
    let loads: Vec<String> = files.iter().map(|f| ruby_string(f)).collect();
    out.push_str(&format!("  loads {}\n", loads.join(", ")));
    for test in tests {
        out.push_str(&format!("\n  test {} do\n", ruby_string(&test.title)));
        out.push_str(&test_text(test));
        out.push_str("  end\n");
    }
    out.push_str("end\n");
    out
}

/// The body of one test: what it exercises, who runs it, what it sets up, gives and expects.
fn test_text(test: &TestOut) -> String {
    let mut out = String::new();
    let command = ruby_string(&test.command);
    let aggregate = ruby_string(&test.aggregate);
    out.push_str(&match &test.subject {
        Subject::Command => format!("    tests {command}, on: {aggregate}\n"),
        Subject::Query => format!("    tests {command}, on: {aggregate}, kind: :query\n"),
        Subject::Arrival { .. } => format!("    tests {command}\n"),
    });
    if let Some(role) = &test.role {
        out.push_str(&format!("    as {}\n", ruby_string(role)));
    }
    for setup in &test.setups {
        let role = setup
            .role
            .as_ref()
            .map_or_else(String::new, |r| format!(", as: {}", ruby_string(r)));
        out.push_str(&format!(
            "    setup {}{role}{}\n",
            ruby_string(&setup.verb),
            hash_args(&setup.args)
        ));
    }
    if let Some(input) = input_text(test) {
        out.push_str(&format!("    input {input}\n"));
    }
    out.push_str(&format!("    expect {}\n", expect_text(&test.expect)));
    out
}

/// The arguments a test gives, if it gives any; a port is addressed to a record.
fn input_text(test: &TestOut) -> Option<String> {
    if let Subject::Arrival { to } = &test.subject {
        let with = hash_args(&test.input);
        let with = with.trim_start_matches(", ");
        return Some(format!("to: {to}, with: {{ {with} }}"));
    }
    (!test.input.is_empty()).then(|| hash_args(&test.input).trim_start_matches(", ").to_string())
}

/// `, slug: { value: "about" }, title: …`, each preceded by a comma and a space.
fn hash_args(args: &[(String, String)]) -> String {
    let mut out = String::new();
    for (name, value) in args {
        out.push_str(", ");
        out.push_str(name);
        out.push_str(": ");
        out.push_str(value);
    }
    out
}

impl Expect {
    /// Whether the example expects anything of the record, the rows or the events.
    const fn has_outcomes(&self) -> bool {
        self.state.is_some()
            || !self.fields.is_empty()
            || self.count.is_some()
            || !self.emits.is_empty()
    }
}

fn expect_text(expect: &Expect) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some((field, state)) = &expect.state {
        parts.push(format!("{field}: {}", ruby_string(state)));
    }
    for (field, value) in &expect.fields {
        parts.push(format!("{field}: {value}"));
    }
    if let Some(count) = expect.count {
        parts.push(format!("count: {count}"));
    }
    if !expect.emits.is_empty() {
        let events: Vec<String> = expect.emits.iter().map(|e| ruby_string(e)).collect();
        parts.push(format!("emits: [{}]", events.join(", ")));
    }
    if let Some(reason) = &expect.refused {
        parts.push(format!("refused: {}", ruby_string(reason)));
    }
    parts.join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(name: &str, emits: &[&str]) -> ir::Command {
        ir::Command {
            name: name.to_string(),
            emits: emits.iter().map(|event| (*event).to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn announced_events_follow_the_policies_that_run_other_commands() {
        let declaration = ir::Bluebook {
            aggregates: vec![ir::Aggregate {
                name: "Order".to_string(),
                commands: vec![
                    command("Place", &["OrderPlaced"]),
                    command("Pack", &["OrderPacked"]),
                    command("Ship", &["OrderShipped"]),
                ],
                ..Default::default()
            }],
            policies: vec![
                ir::Policy {
                    on_event: Some("Order.OrderPlaced".to_string()),
                    trigger_command: Some("Order.Pack".to_string()),
                    ..Default::default()
                },
                ir::Policy {
                    on_event: Some("Order.OrderPacked".to_string()),
                    trigger_command: Some("Order.Ship".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let place = declaration.aggregates[0].commands[0].clone();
        assert_eq!(
            announced_by(&declaration, &Action::Command(&place)),
            ["OrderPlaced", "OrderPacked", "OrderShipped"]
        );
        let ship = declaration.aggregates[0].commands[2].clone();
        assert_eq!(
            announced_by(&declaration, &Action::Command(&ship)),
            ["OrderShipped"]
        );
    }
}
