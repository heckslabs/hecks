//! Drives `hecks-parse` over files written as plain sentences, checking that a good file lowers
//! and that each common mistake is refused in the author's own words, at the line and column it
//! went wrong, with the sentences that would have fitted.

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

const GOOD: &str = "\
Domain: Cms

Aggregate: Page
  A page is identified by its slug.

  It has:
    a slug: page slug
    a title: page title

  A page slug has a value: text.
    Rule \"a page has a slug\" holds when the value is not empty

  A page title has a value: text.

  Lifecycle: status, starting as draft
    Publish moves a page from draft to published

  Command: Draft
    Who: Editor
    When a slug and a title are given
    Then the slug and the title are set
    And PageDrafted is announced

  Command: Publish
    Who: Editor
    It acts on an existing page
    Given \"only a draft can be published\" holds when the status is draft
    Then PagePublished is announced

  Query: Drafts
    The pages not yet published, by slug.
    Where the status is draft
    Ordered by slug.value, ascending
";

fn write(name: &str, source: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("hecks-sentence-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    fs::write(&path, source).unwrap();
    path
}

fn parse(name: &str, source: &str) -> Output {
    let path = write(name, source);
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(["chapter", "--chapter", "Cms", path.to_str().unwrap()])
        .output()
        .expect("failed to run hecks-parse")
}

/// The refusal for `source`, which must be refused.
fn refusal(name: &str, source: &str) -> String {
    let output = parse(name, source);
    assert!(
        !output.status.success(),
        "{name}: expected a refusal, got: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

/// `GOOD` with `from` replaced by `to`; fails if `from` is not in it.
fn changed(from: &str, to: &str) -> String {
    assert!(GOOD.contains(from), "the base file has no line `{from}`");
    GOOD.replacen(from, to, 1)
}

fn line_of(source: &str, needle: &str) -> usize {
    source
        .lines()
        .position(|line| line.contains(needle))
        .map(|index| index + 1)
        .unwrap()
}

#[test]
fn a_good_file_lowers_to_the_chapters_ir() {
    let output = parse("good.bluebook", GOOD);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("\"name\": \"Cms\""), "{stdout}");
    assert!(stdout.contains("\"slug.value\""), "{stdout}");
    assert!(stdout.contains("\"status == \\\"draft\\\"\""), "{stdout}");
}

#[test]
fn a_mistyped_keyword_names_the_column_it_went_wrong_at_and_the_nearest_sentences() {
    let source = changed("Rule \"a page has a slug\"", "Rull \"a page has a slug\"");
    let error = refusal("typo.bluebook", &source);
    let line = line_of(&source, "Rull");
    assert!(error.contains(&format!("typo.bluebook:{line}:5:")), "{error}");
    assert!(error.contains("not a sentence I know in a value object"), "{error}");
    assert!(
        error.contains("expected one of: Rule <description> holds when <condition>"),
        "{error}"
    );
}

#[test]
fn an_unknown_field_in_a_condition_lists_the_fields_in_scope() {
    let source = changed("holds when the status is draft", "holds when the staus is draft");
    let error = refusal("field.bluebook", &source);
    let line = line_of(&source, "staus");
    let column = source.lines().nth(line - 1).unwrap().find("staus").unwrap() + 1;
    assert!(error.contains(&format!("field.bluebook:{line}:{column}:")), "{error}");
    assert!(error.contains("'staus' is not a field here"), "{error}");
    assert!(error.contains("slug, title, status"), "{error}");
}

#[test]
fn an_unknown_type_lists_the_types_that_exist() {
    let source = changed("a title: page title", "a title: pagee title");
    let error = refusal("type.bluebook", &source);
    assert!(error.contains("I don't know a type called 'pagee title'"), "{error}");
    assert!(error.contains("text, whole number, decimal number, page slug, page title"), "{error}");
}

#[test]
fn a_transition_naming_no_command_lists_the_commands_there_are() {
    let source = changed("Publish moves a page", "Publsh moves a page");
    let error = refusal("transition.bluebook", &source);
    assert!(error.contains("no command by that name is declared"), "{error}");
    assert!(error.contains("Commands here: draft, publish"), "{error}");
}

#[test]
fn a_command_cannot_set_what_it_is_not_given() {
    let source = changed("Then the slug and the title are set", "Then the slug, the title and the slug are set\n    And the status is set");
    let error = refusal("sets.bluebook", &source);
    assert!(error.contains("is set from what the command is given"), "{error}");
}

#[test]
fn a_sentence_about_another_aggregate_is_refused() {
    let source = changed("A page is identified by its slug.", "A post is identified by its slug.");
    let error = refusal("owner.bluebook", &source);
    assert!(error.contains("this is about 'post', but it stands in the aggregate 'page'"), "{error}");
}

#[test]
fn an_unclosed_quote_is_refused_with_the_quote_to_close() {
    let source = changed("Rule \"a page has a slug\" holds", "Rule \"a page has a slug holds");
    let error = refusal("quote.bluebook", &source);
    assert!(error.contains("a quote that is closed"), "{error}");
}

#[test]
fn a_line_indented_out_of_step_is_refused() {
    let source = changed("    a title: page title", "      a title: page title");
    let error = refusal("indent.bluebook", &source);
    assert!(error.contains("indented further than the lines above it"), "{error}");
}

#[test]
fn a_tab_in_the_indent_is_refused() {
    let source = changed("    a title: page title", "\ta title: page title");
    let error = refusal("tab.bluebook", &source);
    assert!(error.contains("indented with a tab"), "{error}");
}

#[test]
fn the_wrong_chapter_name_is_refused() {
    let source = changed("Domain: Cms", "Domain: Blog");
    let error = refusal("chapter.bluebook", &source);
    assert!(error.contains("--chapter Cms was requested, but this file declares 'Blog'"), "{error}");
}

#[test]
fn the_ruby_form_and_the_sentence_form_do_not_mix_in_one_chapter() {
    let sentence = write("mixed_sentence.bluebook", GOOD);
    let ruby = write("mixed_ruby.bluebook", "Hecks.bluebook \"Cms\" do\nend\n");
    let output = Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(["chapter", "--chapter", "Cms", sentence.to_str().unwrap(), ruby.to_str().unwrap()])
        .output()
        .expect("failed to run hecks-parse");
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success());
    assert!(error.contains("written in the Ruby form"), "{error}");
}

#[test]
fn a_description_that_opens_a_block_is_not_mistaken_for_prose() {
    let source = changed("  It has:\n", "  It hass:\n");
    let error = refusal("prose.bluebook", &source);
    assert!(error.contains("not a sentence I know in an aggregate"), "{error}");
    assert!(error.contains("It has:"), "{error}");
}
