//! How an examples step names a command: a verb, and the thing the verb acts on.
//!
//! A command named by one word (`Draft`, `Publish`) reads as that verb: `drafts a page` makes a
//! page and `publishes it` acts on the one made earlier. A command named by several words
//! (`CreatePizza`, `AddTopping`) reads as its first word and the rest: `creates a pizza` makes one
//! and `adds a topping to it` acts on the one made earlier. The verb may be the base form
//! (`create`) or the third person (`creates`).

use super::names::spoken;
use crate::ir;

/// A command and the aggregate that declares it.
pub(super) type Found<'c> = (&'c ir::Aggregate, &'c ir::Command);

/// Why a step names no single command.
pub(super) enum Miss {
    /// No command reads that way; the wordings that do read.
    Nothing(Vec<String>),
    /// Several commands read that way, named `Aggregate.Command`.
    Several(Vec<String>),
}

/// What a step says about the thing its verb acts on.
pub(super) struct Object {
    /// The words after the article, lowercased, without a closing `to it`.
    pub(super) words: String,
    /// Whether the step ends in `to it`, acting on a record made earlier.
    pub(super) to_it: bool,
}

impl Object {
    /// Reads the noun slot of a step: `topping to it` is the topping, acting on `it`.
    pub(super) fn of(noun: &str) -> Option<Self> {
        let noun = noun.trim().to_lowercase();
        if noun.is_empty() {
            return None;
        }
        let to_it = noun.ends_with(" to it");
        let words = noun.strip_suffix(" to it").unwrap_or(&noun).to_string();
        Some(Self { words, to_it })
    }
}

/// Whether the command is named by more than one word.
pub(super) fn is_multi_word(command: &ir::Command) -> bool {
    spoken(&command.name).contains(' ')
}

/// The base forms a verb as written may stand for: `tries` is `try`, `adds` is `add`.
pub(super) fn base_forms(verb: &str) -> Vec<String> {
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
    forms
}

/// The third-person form of a verb: `add` is `adds`, `publish` is `publishes`, `try` is `tries`.
pub(super) fn third_person(base: &str) -> String {
    if let Some(stem) = base.strip_suffix('y') {
        if !stem.is_empty() && !stem.ends_with(['a', 'e', 'i', 'o', 'u']) {
            return format!("{stem}ies");
        }
    }
    if base.ends_with(['s', 'x', 'z', 'o']) || base.ends_with("sh") || base.ends_with("ch") {
        return format!("{base}es");
    }
    format!("{base}s")
}

/// `a` or `an` for the word that follows.
pub(super) fn article(word: &str) -> &'static str {
    if word.starts_with(['a', 'e', 'i', 'o', 'u']) {
        "an"
    } else {
        "a"
    }
}

/// The word with its article: `a pizza`, `an order`.
pub(super) fn with_article(word: &str) -> String {
    format!("{} {word}", article(word))
}

/// The command a verb and object name, among every command of the bluebook.
pub(super) fn find<'c>(
    declaration: &'c ir::Bluebook,
    verb: &str,
    object: Option<&Object>,
) -> Result<Found<'c>, Miss> {
    let forms = base_forms(verb);
    let all: Vec<Found<'c>> = declaration
        .aggregates
        .iter()
        .flat_map(|aggregate| aggregate.commands.iter().map(move |c| (aggregate, c)))
        .collect();
    let found: Vec<Found<'c>> = all
        .iter()
        .copied()
        .filter(|(_, command)| reads_as(command, &forms, object))
        .collect();
    match found.as_slice() {
        [one] => Ok(*one),
        [] => Err(Miss::Nothing(
            all.iter().map(|(a, c)| wording(a, c)).collect(),
        )),
        many => Err(Miss::Several(
            many.iter()
                .map(|(a, c)| format!("{}.{}", a.name, c.name))
                .collect(),
        )),
    }
}

/// A step's verb and object as it was written, for a refusal to quote.
pub(super) fn as_said(verb: &str, object: Option<&Object>) -> String {
    let Some(object) = object else {
        return verb.to_string();
    };
    let tail = if object.to_it { " to it" } else { "" };
    format!("{verb} {} {}{tail}", article(&object.words), object.words)
}

/// Whether a command reads as one of the verbs, with the object the step gave.
fn reads_as(command: &ir::Command, forms: &[String], object: Option<&Object>) -> bool {
    let name = spoken(&command.name);
    match name.split_once(' ') {
        None => forms.contains(&name),
        Some((verb, rest)) => {
            forms.iter().any(|form| form == verb) && object.is_some_and(|o| o.words == rest)
        }
    }
}

/// How a step reads for a command, without who does it or the values: `adds a topping to it`.
pub(super) fn wording(aggregate: &ir::Aggregate, command: &ir::Command) -> String {
    let name = spoken(&command.name);
    let acts_on_it = command.references.is_some();
    match name.split_once(' ') {
        None if acts_on_it => format!("{} it", third_person(&name)),
        None => {
            let noun = spoken(&aggregate.name);
            format!("{} {} {noun}", third_person(&name), article(&noun))
        }
        Some((verb, rest)) => {
            let tail = if acts_on_it { " to it" } else { "" };
            format!("{} {} {rest}{tail}", third_person(verb), article(rest))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_verb_takes_the_ending_its_last_letters_ask_for() {
        let said: Vec<String> = ["add", "publish", "try", "buy", "go", "fix", "watch", "pass"]
            .iter()
            .map(|verb| third_person(verb))
            .collect();
        assert_eq!(
            said,
            [
                "adds",
                "publishes",
                "tries",
                "buys",
                "goes",
                "fixes",
                "watches",
                "passes"
            ]
        );
    }

    #[test]
    fn a_verb_as_written_stands_for_its_base_form() {
        assert!(base_forms("tries").contains(&"try".to_string()));
        assert!(base_forms("publishes").contains(&"publish".to_string()));
        assert!(base_forms("adds").contains(&"add".to_string()));
        assert!(base_forms("add").contains(&"add".to_string()));
    }

    #[test]
    fn the_noun_of_a_step_says_whether_it_acts_on_it() {
        let acting = Object::of("Topping to it").unwrap();
        assert_eq!((acting.words.as_str(), acting.to_it), ("topping", true));
        let making = Object::of("pizza").unwrap();
        assert_eq!((making.words.as_str(), making.to_it), ("pizza", false));
        assert!(Object::of("  ").is_none());
    }

    #[test]
    fn the_article_follows_the_sound_of_the_word() {
        assert_eq!(article("order"), "an");
        assert_eq!(article("pizza"), "a");
    }
}
