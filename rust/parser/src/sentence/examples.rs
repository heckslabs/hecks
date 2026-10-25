//! Examples: a `.examples` file, written as sentences, compiled to the `.behaviors` text that
//! runs it against the domain it is about.
//!
//! An example says who does what and what follows, in the domain's own words. Every name in it is
//! checked against the parsed chapter, so an example can only mean something the domain declares:
//! a person's role, a command and the fields it takes, a lifecycle state, an event, a rule's own
//! sentence. What does not resolve is refused with what would have.

// reason: this builds a few kilobytes of text a line at a time; an allocation per line costs
// nothing and `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use super::names::{camel, snake, spoken};
use super::token::{tokenize, Kind};
use super::{column, read_lines, Grammar, Matched, Parser, Scope, Step};
use crate::diag::ParseResult;
use crate::ir;
use crate::render_ruby::string as ruby_string;

/// Compiles an examples file to `.behaviors` text.
///
/// `chapter` is the parsed domain the examples are about; `chapter_files` are the absolute paths
/// of its files, which the suite boots.
pub fn compile(
    chapter: &ir::Bluebook,
    chapter_files: &[String],
    path: &str,
    source: &str,
) -> ParseResult<String> {
    let grammar = Grammar::load()?;
    let lines = read_lines(path, source)?;
    let mut parser = Parser::new(path, &grammar, lines);
    let tests = parser.examples(chapter)?;
    Ok(behaviors_text(chapter, chapter_files, path, &tests))
}

/// A person introduced under `Background:`.
struct Person {
    name: String,
    role: String,
}

/// A value written in an example's arguments.
enum Literal {
    Text(String),
    Whole(String),
    Decimal(String),
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
    command: &'c ir::Command,
    /// The fields that name the record the command acts on, for a step that acts on `it`.
    identity: Vec<(String, String)>,
    args: Vec<(String, String)>,
    tries: bool,
    line: usize,
    col: usize,
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
    emits: Vec<String>,
    refused: Option<String>,
}

/// One compiled test.
struct TestOut {
    title: String,
    aggregate: String,
    command: String,
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
    fn examples(&mut self, chapter: &ir::Bluebook) -> ParseResult<Vec<TestOut>> {
        let mut top = Scope::top();
        let Some(Step::Phrase(header)) = self.step(&mut top, "ExamplesFile", false)? else {
            return Err(self.error(1, 1, "this file is empty; it starts with `Examples for: <chapter>`"));
        };
        let named = camel(&header.text_of("name"));
        if named != chapter.name {
            return Err(self.error(
                header.line,
                header.col_of("name"),
                format!("these examples are about '{named}', but the chapter is '{}'", chapter.name),
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
                "example" => tests.extend(self.example(&m, chapter, &people)?),
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
                return Err(self.error(m.line, m.col_of("person"), format!("{name} is introduced twice")));
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
        chapter: &ir::Bluebook,
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
        let several = rows.len() > 1 || rows.first().is_some_and(|row: &Vec<(String, String)>| !row.is_empty());
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
            tests.push(self.interpret(chapter, people, &named, header, &filled)?);
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
                return Err(self.error(line.number, line.indent + 1, "a Where table is made of `| cell | cell |` lines"));
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
            return Err(self.error(header.line, header.base_col, "this Where has no table under it"));
        };
        let rows: Vec<Vec<String>> = rows.collect();
        if let Some(bad) = rows.iter().find(|row| row.len() != columns.len()) {
            return Err(self.error(
                header.line,
                header.base_col,
                format!("a row has {} cells, but the table has {} columns: {}", bad.len(), columns.len(), columns.join(", ")),
            ));
        }
        if rows.is_empty() {
            return Err(self.error(header.line, header.base_col, "this Where has columns but no rows"));
        }
        Ok(Table { columns, rows })
    }

    /// Turns one example's lines into a test.
    fn interpret<'c>(
        &self,
        chapter: &'c ir::Bluebook,
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
            let current = if raw.keyword == Keyword::And { section } else { raw.keyword };
            section = current;
            match current {
                Keyword::Given | Keyword::And => {
                    let step = self.dispatch(chapter, people, raw, &mut created)?;
                    if step.tries {
                        return Err(self.error(raw.line, raw.col, "a Given step has to succeed; put the step that is refused under When"));
                    }
                    setups.push(step);
                }
                Keyword::When => {
                    if tested.is_some() {
                        return Err(self.error(raw.line, raw.col, "an example proves one action; this is a second When"));
                    }
                    tested = Some(self.dispatch(chapter, people, raw, &mut created)?);
                }
                Keyword::Then => outcomes.push(raw),
            }
        }
        let Some(tested) = tested else {
            return Err(self.error(header.line, header.base_col, "this example has no `When` step"));
        };
        let mut expect = Expect::default();
        for raw in outcomes {
            self.outcome(chapter, raw, &tested, &mut expect)?;
        }
        self.consistent(&tested, &expect)?;
        let input: Vec<(String, String)> = tested.identity.iter().chain(tested.args.iter()).cloned().collect();
        Ok(TestOut {
            title: title.to_string(),
            aggregate: tested.aggregate.name.clone(),
            command: tested.command.name.clone(),
            role: tested.role,
            setups: setups
                .into_iter()
                .map(|step| SetupOut {
                    verb: format!("{}::{}.{}", chapter.name, step.aggregate.name, step.command.name),
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
        chapter: &'c ir::Bluebook,
        people: &[Person],
        raw: &Raw,
        created: &mut Vec<Created>,
    ) -> ParseResult<Dispatch<'c>> {
        let (phrase, found) = self.match_text("Step", &raw.text, raw.col).map_err(|unmatched| {
            self.error(raw.line, unmatched.column, format!("this is not a step I know: \"{}\"", raw.text))
                .with_expected(unmatched.suggestions)
        })?;
        let id = phrase.row.id;
        let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
        let at = |name: &str| column(raw.col, &raw.text, slot(name).offset);

        let who = slot("who").value;
        let role = self.role_of(people, &who, raw.line, at("who"))?;
        let (aggregate, command) = self.find_command(chapter, &slot("verb").value, raw.line, at("verb"))?;

        let acts_on_it = id.contains("acts");
        if acts_on_it {
            if command.references.is_none() {
                return Err(self.error(
                    raw.line,
                    at("verb"),
                    format!(
                        "{} makes a {} rather than acting on one that exists; write `{} {}s a {} with …`",
                        spoken(&command.name),
                        spoken(&aggregate.name),
                        who,
                        slot("verb").value,
                        spoken(&aggregate.name)
                    ),
                ));
            }
        } else {
            if command.references.is_some() {
                return Err(self.error(
                    raw.line,
                    at("verb"),
                    format!(
                        "{} acts on a {} that exists; write `{who} {} it`",
                        spoken(&command.name),
                        spoken(&aggregate.name),
                        slot("verb").value
                    ),
                ));
            }
            let noun = slot("noun").value.to_lowercase();
            if noun != spoken(&aggregate.name) {
                return Err(self.error(
                    raw.line,
                    at("noun"),
                    format!("{} makes a {}, not a {noun}", spoken(&command.name), spoken(&aggregate.name)),
                ));
            }
        }

        let args = if id.ends_with("bare") {
            Vec::new()
        } else {
            self.arguments(aggregate, command, &slot("args").value, raw.line, at("args"))?
        };
        let identity = if acts_on_it {
            created
                .iter()
                .rev()
                .find(|record| record.aggregate == aggregate.name)
                .map(|record| record.identity.clone())
                .ok_or_else(|| {
                    self.error(
                        raw.line,
                        raw.col,
                        format!("there is no {} yet for `it` to mean; create one in an earlier step", spoken(&aggregate.name)),
                    )
                })?
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
            command,
            identity,
            args,
            tries: id.starts_with("step_tries"),
            line: raw.line,
            col: raw.col,
        })
    }

    /// The role a person holds, or `the Editor` named outright.
    fn role_of(&self, people: &[Person], who: &str, line: usize, col: usize) -> ParseResult<String> {
        if let Some(person) = people.iter().find(|p| p.name.eq_ignore_ascii_case(who)) {
            return Ok(person.role.clone());
        }
        if let Some(role) = who.strip_prefix("the ").or_else(|| who.strip_prefix("The ")) {
            return Ok(role.to_string());
        }
        let known: Vec<String> = people.iter().map(|p| format!("{} ({})", p.name, p.role)).collect();
        Err(self.error(
            line,
            col,
            format!(
                "I don't know who '{who}' is. Introduce them under Background, like `Dana is an Editor`, or write `the <role>`. Known: {}",
                if known.is_empty() { "nobody".to_string() } else { known.join(", ") }
            ),
        ))
    }

    /// The command a verb names, in the form a step uses it: `drafts` is `Draft`.
    fn find_command<'c>(
        &self,
        chapter: &'c ir::Bluebook,
        verb: &str,
        line: usize,
        col: usize,
    ) -> ParseResult<(&'c ir::Aggregate, &'c ir::Command)> {
        let lowered = verb.to_lowercase();
        let mut forms = vec![lowered.clone()];
        if let Some(stem) = lowered.strip_suffix("ies") {
            forms.push(format!("{stem}y"));
        }
        if let Some(stem) = lowered.strip_suffix("es") {
            forms.push(stem.to_string());
        }
        if let Some(stem) = lowered.strip_suffix('s') {
            forms.push(stem.to_string());
        }
        let all: Vec<(&ir::Aggregate, &ir::Command)> = chapter
            .aggregates
            .iter()
            .flat_map(|aggregate| aggregate.commands.iter().map(move |command| (aggregate, command)))
            .collect();
        let found: Vec<(&ir::Aggregate, &ir::Command)> = all
            .iter()
            .copied()
            .filter(|(_, command)| forms.contains(&command.name.to_lowercase()))
            .collect();
        match found.as_slice() {
            [one] => Ok(*one),
            [] => Err(self.error(
                line,
                col,
                format!(
                    "'{verb}' is not a command here. The commands are: {}",
                    all.iter().map(|(_, c)| spoken(&c.name)).collect::<Vec<_>>().join(", ")
                ),
            )),
            _ => Err(self.error(line, col, format!("more than one aggregate has a command called '{verb}'"))),
        }
    }

    /// Reads `slug "about" and title "About us"` into the command's argument values.
    fn arguments(
        &self,
        aggregate: &ir::Aggregate,
        command: &ir::Command,
        text: &str,
        line: usize,
        base_col: usize,
    ) -> ParseResult<Vec<(String, String)>> {
        let Ok(tokens) = tokenize(text) else {
            return Err(self.error(line, base_col, "a quote is not closed"));
        };
        let mut given: Vec<(String, String)> = Vec::new();
        let mut words: Vec<&str> = Vec::new();
        for token in &tokens {
            let literal = match token.kind {
                Kind::Quoted => Some(Literal::Text(token.text.clone())),
                Kind::Word if is_whole(&token.text) => Some(Literal::Whole(token.text.clone())),
                Kind::Word if is_decimal(&token.text) => Some(Literal::Decimal(token.text.clone())),
                Kind::Word => {
                    let separator = token.text.eq_ignore_ascii_case("and") && words.is_empty();
                    if !separator {
                        words.push(&token.text);
                    }
                    None
                }
                Kind::Punct(',') => None,
                Kind::Punct(_) => {
                    return Err(self.error(line, column(base_col, text, token.start), "unexpected punctuation in the values"));
                }
            };
            let Some(literal) = literal else { continue };
            let col = column(base_col, text, token.start);
            let mut name = words.clone();
            if name.first().is_some_and(|w| matches!(w.to_lowercase().as_str(), "a" | "an" | "the")) {
                name.remove(0);
            }
            if name.is_empty() {
                return Err(self.error(line, col, "this value has no field name before it"));
            }
            words.clear();
            let field = snake(&name.join(" "));
            let Some(attribute) = command.attributes.iter().find(|a| a.name == field) else {
                let fields: Vec<String> = command.attributes.iter().map(|a| spoken(&a.name)).collect();
                return Err(self.error(
                    line,
                    col,
                    format!(
                        "{} takes no '{}'. It takes: {}",
                        spoken(&command.name),
                        name.join(" "),
                        if fields.is_empty() { "nothing".to_string() } else { fields.join(", ") }
                    ),
                ));
            };
            given.push((field, self.value_of(aggregate, attribute, &literal, line, col)?));
        }
        if let Some(word) = words.first() {
            return Err(self.error(line, base_col, format!("'{word}' has no value after it")));
        }
        for attribute in &command.attributes {
            let supplied = given.iter().any(|(name, _)| *name == attribute.name);
            if !supplied && !attribute.optional && attribute.default.is_none() {
                return Err(self.error(
                    line,
                    base_col,
                    format!("{} needs a {}", spoken(&command.name), spoken(&attribute.name)),
                ));
            }
        }
        Ok(given)
    }

    /// A literal as the argument `attribute` takes: bare for a scalar, `{ value: … }` for a value
    /// object that holds one value.
    fn value_of(
        &self,
        aggregate: &ir::Aggregate,
        attribute: &ir::Attribute,
        literal: &Literal,
        line: usize,
        col: usize,
    ) -> ParseResult<String> {
        let (scalar, wrapped) = if matches!(attribute.type_name.as_str(), "String" | "Integer" | "Float") {
            (attribute.type_name.clone(), false)
        } else {
            let Some(object) = aggregate.value_objects.iter().find(|v| v.name == attribute.type_name) else {
                return Err(self.error(line, col, format!("I don't know how to write a value for {}", spoken(&attribute.name))));
            };
            match object.attributes.as_slice() {
                [only] if only.name == "value" => (only.type_name.clone(), true),
                _ => {
                    return Err(self.error(
                        line,
                        col,
                        format!("{} holds more than one value; examples can only give a single value so far", spoken(&attribute.name)),
                    ));
                }
            }
        };
        let rendered = match (scalar.as_str(), literal) {
            ("String", Literal::Text(text)) => ruby_string(text),
            ("Integer", Literal::Whole(digits)) | ("Float", Literal::Whole(digits) | Literal::Decimal(digits)) => {
                digits.clone()
            }
            (expected, _) => {
                let wanted = match expected {
                    "String" => "text in quotes",
                    "Integer" => "a whole number",
                    _ => "a number",
                };
                return Err(self.error(line, col, format!("{} is {wanted}", spoken(&attribute.name))));
            }
        };
        Ok(if wrapped { format!("{{ value: {rendered} }}") } else { rendered })
    }

    /// Reads one `Then` or `And` line after the tested step.
    fn outcome(
        &self,
        chapter: &ir::Bluebook,
        raw: &Raw,
        tested: &Dispatch<'_>,
        expect: &mut Expect,
    ) -> ParseResult<()> {
        let text = raw.text.strip_suffix('.').unwrap_or(&raw.text);
        let (phrase, found) = self.match_text("Outcome", text, raw.col).map_err(|unmatched| {
            self.error(raw.line, unmatched.column, format!("this is not an outcome I know: \"{}\"", raw.text))
                .with_expected(unmatched.suggestions)
        })?;
        let slot = |name: &str| found.get(name).cloned().unwrap_or_default();
        let at = |name: &str| column(raw.col, text, slot(name).offset);
        match phrase.row.id {
            "outcome_state" => {
                let noun = slot("noun").value.to_lowercase();
                if noun != spoken(&tested.aggregate.name) {
                    return Err(self.error(raw.line, at("noun"), format!("the example is about a {}, not a {noun}", spoken(&tested.aggregate.name))));
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
                    return Err(self.error(raw.line, at("state"), format!("a {noun} is never {state}. Its states are: {}", unique(&states).join(", "))));
                }
                expect.state = Some((lifecycle.field.clone(), state));
            }
            "outcome_announced" => {
                let event = slot("event").value;
                let announced = announced_by(chapter, tested.command);
                if !announced.contains(&event) {
                    return Err(self.error(
                        raw.line,
                        at("event"),
                        format!("{} announces {}, not {event}", spoken(&tested.command.name), announced.join(", ")),
                    ));
                }
                expect.emits.push(event);
            }
            "outcome_refused_role" => {
                let named = slot("role").value;
                let declared: Vec<String> = if tested.command.roles.is_empty() {
                    tested.command.role.iter().cloned().collect()
                } else {
                    tested.command.roles.clone()
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
                            spoken(&tested.command.name),
                            if declared.is_empty() { "anyone".to_string() } else { declared.join(" or ") }
                        ),
                    ));
                }
                let caller = tested.role.clone().unwrap_or_default();
                expect.refused = Some(format!("role: {}, and the caller stated {caller}", declared.join(" or ")));
            }
            "outcome_refused" => {
                let reason = slot("reason").value;
                let reason = reason.strip_suffix('.').unwrap_or(&reason).to_string();
                let rules = rules_of(tested);
                if !rules.contains(&reason) {
                    return Err(self.error(
                        raw.line,
                        at("reason"),
                        format!(
                            "no rule of {} says \"{reason}\". The rules are: {}",
                            spoken(&tested.command.name),
                            if rules.is_empty() { "none".to_string() } else { rules.iter().map(|r| format!("\"{r}\"")).collect::<Vec<_>>().join(", ") }
                        ),
                    ));
                }
                expect.refused = Some(reason);
            }
            _ => {
                return Err(self.error(raw.line, raw.col, format!("the outcome '{}' is admitted but not read yet", phrase.row.id)));
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
            return Err(self.error(tested.line, tested.col, "this example expects a refusal, so the step should read `… tries to …`"));
        }
        if expect.refused.is_some() && (expect.state.is_some() || !expect.emits.is_empty()) {
            return Err(self.error(tested.line, tested.col, "a refused command changes nothing; an example is either refused or has outcomes"));
        }
        if expect.refused.is_none() && expect.state.is_none() && expect.emits.is_empty() {
            return Err(self.error(tested.line, tested.col, "this example proves nothing; add a `Then`"));
        }
        Ok(())
    }
}

/// Every event a command announces, including those announced by commands that policies run in
/// answer to its events, and so on until nothing new follows.
fn announced_by(chapter: &ir::Bluebook, command: &ir::Command) -> Vec<String> {
    let mut events: Vec<String> = command.emits.clone();
    let mut grew = true;
    while grew {
        grew = false;
        for policy in &chapter.policies {
            let Some(on) = policy.on_event.as_deref() else { continue };
            let event = on.split_once('.').map_or(on, |(_, name)| name);
            let Some(trigger) = policy.trigger_command.as_deref() else { continue };
            if !events.iter().any(|known| known == event) {
                continue;
            }
            for aggregate in &chapter.aggregates {
                for next in aggregate.commands.iter().filter(|c| format!("{}.{}", aggregate.name, c.name) == trigger) {
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

/// Every sentence a refusal of this step may give: the command's rules and the value objects'.
fn rules_of(step: &Dispatch<'_>) -> Vec<String> {
    let mut rules: Vec<String> = step
        .command
        .givens
        .iter()
        .filter_map(|given| given.description.clone())
        .collect();
    for object in &step.aggregate.value_objects {
        rules.extend(object.invariants.iter().filter_map(|rule| rule.description.clone()));
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
                        format!("this step does not give the {} that identifies the {}", spoken(name), spoken(&aggregate.name)),
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

fn is_whole(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_digit())
}

fn is_decimal(text: &str) -> bool {
    text.split_once('.')
        .is_some_and(|(whole, fraction)| is_whole(whole) && is_whole(fraction))
}

/// Replaces each `<column>` in `text` with the row's cell.
fn substitute(text: &str, row: &[(String, String)]) -> String {
    row.iter()
        .fold(text.to_string(), |acc, (name, cell)| acc.replace(&format!("<{name}>"), cell))
}

/// The `.behaviors` text that runs the compiled tests.
fn behaviors_text(chapter: &ir::Bluebook, files: &[String], path: &str, tests: &[TestOut]) -> String {
    let file = path.rsplit('/').next().unwrap_or(path);
    let mut out = format!("Hecks.behaviors {} do\n", ruby_string(&format!("{} examples", chapter.name)));
    out.push_str(&format!("  vision {}\n", ruby_string(&format!("Examples written as sentences in {file}."))));
    let loads: Vec<String> = files.iter().map(|f| ruby_string(f)).collect();
    out.push_str(&format!("  loads {}\n", loads.join(", ")));
    for test in tests {
        out.push_str(&format!("\n  test {} do\n", ruby_string(&test.title)));
        out.push_str(&format!(
            "    tests {}, on: {}\n",
            ruby_string(&test.command),
            ruby_string(&test.aggregate)
        ));
        if let Some(role) = &test.role {
            out.push_str(&format!("    as {}\n", ruby_string(role)));
        }
        for setup in &test.setups {
            let role = setup.role.as_ref().map_or_else(String::new, |r| format!(", as: {}", ruby_string(r)));
            out.push_str(&format!("    setup {}{role}{}\n", ruby_string(&setup.verb), hash_args(&setup.args)));
        }
        if !test.input.is_empty() {
            out.push_str(&format!("    input {}\n", hash_args(&test.input).trim_start_matches(", ")));
        }
        out.push_str(&format!("    expect {}\n", expect_text(&test.expect)));
        out.push_str("  end\n");
    }
    out.push_str("end\n");
    out
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

fn expect_text(expect: &Expect) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some((field, state)) = &expect.state {
        parts.push(format!("{field}: {}", ruby_string(state)));
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
        let chapter = ir::Bluebook {
            aggregates: vec![ir::Aggregate {
                name: "Order".to_string(),
                commands: vec![command("Place", &["OrderPlaced"]), command("Pack", &["OrderPacked"]), command("Ship", &["OrderShipped"])],
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
        let place = chapter.aggregates[0].commands[0].clone();
        assert_eq!(announced_by(&chapter, &place), ["OrderPlaced", "OrderPacked", "OrderShipped"]);
        let ship = chapter.aggregates[0].commands[2].clone();
        assert_eq!(announced_by(&chapter, &ship), ["OrderShipped"]);
    }

    #[test]
    fn a_decimal_and_a_whole_number_are_told_apart() {
        assert!(is_whole("1700000000") && !is_whole("1.5") && !is_whole(""));
        assert!(is_decimal("1.5") && !is_decimal("15") && !is_decimal("1."));
    }
}
