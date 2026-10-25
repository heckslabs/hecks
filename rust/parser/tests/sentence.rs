//! Drives `hecks-parse` over files written as plain sentences, checking that a good file lowers
//! and that each common mistake is refused in the author's own words, at the line and column it
//! went wrong, with the sentences that would have fitted.

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]
// reason: a `${1:goal}` snippet in an expected string is the editor's syntax, not a format
// argument.
#![allow(clippy::literal_string_with_formatting_args)]

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

const EXAMPLES: &str = "\
Examples for: Cms

Background:
  Dana is an Editor
  Sam is a Viewer

Example: Publishing
  Given Dana drafts a page with slug \"about\" and title \"About\"
  When Dana publishes it
  Then the page is published
  And PagePublished is announced

Example: Only an editor may publish
  Given Dana drafts a page with slug \"about\" and title \"About\"
  When <person> tries to publish it
  Then it is refused because only an Editor may do it

  Where:
    | person |
    | Sam    |
";

fn compile_examples(name: &str, examples: &str) -> Output {
    let chapter = write(&format!("examples_{name}.bluebook"), GOOD);
    let source = write(&format!("examples_{name}.examples"), examples);
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args([
            "examples",
            "--chapter",
            "Cms",
            "--examples",
            source.to_str().unwrap(),
            chapter.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run hecks-parse")
}

/// The refusal for `EXAMPLES` with `from` replaced by `to`.
fn examples_refusal(name: &str, from: &str, to: &str) -> String {
    assert!(EXAMPLES.contains(from), "the base examples have no line `{from}`");
    let output = compile_examples(name, &EXAMPLES.replacen(from, to, 1));
    assert!(
        !output.status.success(),
        "{name}: expected a refusal, got: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

#[test]
fn examples_compile_to_behaviors_text_with_roles_values_and_expectations() {
    let output = compile_examples("examples_good", EXAMPLES);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(text.contains("test \"Publishing\" do"), "{text}");
    assert!(text.contains("tests \"Publish\", on: \"Page\""), "{text}");
    assert!(
        text.contains("setup \"Cms::Page.Draft\", as: \"Editor\", slug: { value: \"about\" }, title: { value: \"About\" }"),
        "{text}"
    );
    assert!(text.contains("input slug: { value: \"about\" }"), "{text}");
    assert!(text.contains("expect status: \"published\", emits: [\"PagePublished\"]"), "{text}");
    assert!(text.contains("test \"Only an editor may publish (Sam)\" do"), "{text}");
    assert!(text.contains("as \"Viewer\""), "{text}");
    assert!(text.contains("expect refused: \"role: Editor, and the caller stated Viewer\""), "{text}");
}

#[test]
fn an_example_about_someone_unintroduced_lists_who_is_known() {
    let error = examples_refusal("who", "Given Dana drafts", "Given Pat drafts");
    assert!(error.contains("examples_who.examples:8:"), "{error}");
    assert!(error.contains("I don't know who 'Pat' is"), "{error}");
    assert!(error.contains("Known: Dana (Editor), Sam (Viewer)"), "{error}");
}

#[test]
fn an_example_naming_no_command_lists_the_commands() {
    let error = examples_refusal("verb", "When Dana publishes it", "When Dana renames it");
    assert!(error.contains("'renames' is not a command here"), "{error}");
    assert!(error.contains("The commands are: draft, publish"), "{error}");
}

#[test]
fn an_example_giving_an_unknown_field_lists_the_fields_the_command_takes() {
    let error = examples_refusal("field", "with slug \"about\"", "with slugg \"about\"");
    assert!(error.contains("draft takes no 'slugg'. It takes: slug, title"), "{error}");
    assert!(error.contains("examples_field.examples:8:39:"), "{error}");
}

#[test]
fn an_example_leaving_out_a_required_value_says_which() {
    let error = examples_refusal("missing", " and title \"About\"\n  When", "\n  When");
    assert!(error.contains("draft needs a title"), "{error}");
}

#[test]
fn an_example_expecting_a_state_the_page_never_has_lists_its_states() {
    let error = examples_refusal("state", "the page is published", "the page is archived");
    assert!(error.contains("a page is never archived. Its states are: draft, published"), "{error}");
}

#[test]
fn an_example_announcing_an_event_the_command_does_not_is_refused() {
    let error = examples_refusal("event", "And PagePublished is announced", "And PageDrafted is announced");
    assert!(error.contains("publish announces PagePublished, not PageDrafted"), "{error}");
}

#[test]
fn an_example_that_tries_something_must_say_why_it_is_refused() {
    let error = examples_refusal("tries", "When Dana publishes it", "When Dana tries to publish it");
    assert!(error.contains("this step tries to do something"), "{error}");
}

#[test]
fn a_refusal_has_to_be_one_of_the_commands_own_rules() {
    let error = examples_refusal(
        "reason",
        "Then it is refused because only an Editor may do it",
        "Then it is refused because it is Tuesday",
    );
    assert!(error.contains("no rule of publish says \"it is Tuesday\""), "{error}");
    assert!(error.contains("\"only a draft can be published\""), "{error}");
}

#[test]
fn it_needs_something_made_earlier_in_the_example() {
    let error = examples_refusal(
        "early",
        "Given Dana drafts a page with slug \"about\" and title \"About\"\n  When Dana publishes it",
        "Given Dana publishes it\n  When Dana publishes it",
    );
    assert!(error.contains("there is no page yet for `it` to mean"), "{error}");
}

#[test]
fn only_the_role_a_command_is_run_by_may_be_named_as_the_one_refused() {
    let error = examples_refusal("role", "only an Editor may do it", "only a Viewer may do it");
    assert!(error.contains("publish is run by Editor, not by Viewer"), "{error}");
}

/// `GOOD` with a policy that runs `Publish` when a page is drafted.
fn with_policy(policy: &str) -> String {
    format!("{GOOD}\nPolicy: Publish When Drafted\n{policy}")
}

#[test]
fn a_policy_lowers_to_the_event_it_waits_for_and_the_command_it_runs() {
    let source = with_policy("  Whenever PageDrafted is announced\n  Then Publish runs\n");
    let output = parse("policy_good.bluebook", &source);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("\"name\": \"PublishWhenDrafted\""), "{stdout}");
    assert!(stdout.contains("\"on_event\": \"Page.PageDrafted\""), "{stdout}");
    assert!(stdout.contains("\"trigger_command\": \"Page.Publish\""), "{stdout}");
}

#[test]
fn a_policy_that_asks_the_outside_names_the_need_and_the_fields_it_passes() {
    let source = with_policy("  Whenever PageDrafted is announced\n  Then review is asked with the slug and the title\n");
    let output = parse("policy_ask.bluebook", &source);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("\"ask\": \"review\""), "{stdout}");
    assert!(stdout.contains("\":slug\""), "{stdout}");
}

#[test]
fn a_policy_waiting_for_an_event_no_command_announces_says_how_to_name_an_outside_one() {
    let source = with_policy("  Whenever PageArchived is announced\n  Then Publish runs\n");
    let error = refusal("policy_event.bluebook", &source);
    assert!(error.contains("no command announces PageArchived. The events announced are: PageDrafted, PagePublished"), "{error}");
    assert!(error.contains("announced by an <aggregate>"), "{error}");
}

#[test]
fn an_event_the_outside_announces_is_named_with_the_aggregate_it_belongs_to() {
    let source = with_policy("  Whenever PageReviewed is announced by a page\n  Then Publish runs\n");
    let output = parse("policy_outside.bluebook", &source);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(String::from_utf8_lossy(&output.stdout).contains("\"on_event\": \"Page.PageReviewed\""));
}

#[test]
fn a_policy_running_no_such_command_lists_the_commands() {
    let source = with_policy("  Whenever PageDrafted is announced\n  Then Archive runs\n");
    let error = refusal("policy_command.bluebook", &source);
    assert!(error.contains("'archive' is not one command of this chapter. The commands are: draft, publish"), "{error}");
}

#[test]
fn a_policy_passing_a_field_the_command_does_not_take_says_what_it_takes() {
    let source = with_policy("  Whenever PageDrafted is announced\n  Then Publish runs with the slug\n");
    let error = refusal("policy_field.bluebook", &source);
    assert!(error.contains("publish takes no 'slug'. It takes: nothing"), "{error}");
}

#[test]
fn a_policy_must_say_when_and_what() {
    let error = refusal("policy_when.bluebook", &with_policy("  Then Publish runs\n"));
    assert!(error.contains("has no `Whenever <event> is announced`"), "{error}");
    let error = refusal("policy_then.bluebook", &with_policy("  Whenever PageDrafted is announced\n"));
    assert!(error.contains("this policy does nothing"), "{error}");
}

#[test]
fn policies_survive_the_formatter_and_the_ruby_form() {
    let source = write(
        "policy_trip.bluebook",
        &with_policy("  Whenever PageReviewed is announced by a page\n  Then Publish runs\n"),
    );
    let before = run_on("chapter", source.to_str().unwrap());
    let formatted = run_on("format", source.to_str().unwrap());
    assert!(formatted.status.success(), "{}", String::from_utf8_lossy(&formatted.stderr));
    let again = write("policy_trip_again.bluebook", &String::from_utf8_lossy(&formatted.stdout));
    assert_eq!(
        String::from_utf8_lossy(&before.stdout),
        String::from_utf8_lossy(&run_on("chapter", again.to_str().unwrap()).stdout)
    );

    let rendered = run_on("render", source.to_str().unwrap());
    let text = String::from_utf8_lossy(&rendered.stdout).into_owned();
    assert!(text.contains("trigger Page::Publish"), "{text}");
    let ruby = write("policy_trip_ruby.bluebook", &text);
    assert_eq!(
        String::from_utf8_lossy(&before.stdout),
        String::from_utf8_lossy(&run_on("chapter", ruby.to_str().unwrap()).stdout)
    );
}

fn run_on(subcommand: &str, path: &str) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args([subcommand, "--chapter", "Cms", path])
        .output()
        .expect("failed to run hecks-parse")
}

#[test]
fn the_rendered_ruby_form_reads_back_to_the_same_ir() {
    let sentences = write("round_trip.bluebook", GOOD);
    let first = run_on("chapter", sentences.to_str().unwrap());
    let rendered = run_on("render", sentences.to_str().unwrap());
    assert!(rendered.status.success(), "{}", String::from_utf8_lossy(&rendered.stderr));

    let ruby = write("round_trip_ruby.bluebook", &String::from_utf8_lossy(&rendered.stdout));
    let second = run_on("chapter", ruby.to_str().unwrap());
    assert!(second.status.success(), "{}", String::from_utf8_lossy(&second.stderr));
    assert_eq!(
        String::from_utf8_lossy(&first.stdout),
        String::from_utf8_lossy(&second.stdout)
    );
}

#[test]
fn the_formatter_is_the_reverse_of_the_parser_and_settles_on_one_wording() {
    let source = write("format.bluebook", GOOD);
    let before = run_on("chapter", source.to_str().unwrap());
    let formatted = run_on("format", source.to_str().unwrap());
    assert!(formatted.status.success(), "{}", String::from_utf8_lossy(&formatted.stderr));

    let again = write("format_again.bluebook", &String::from_utf8_lossy(&formatted.stdout));
    let after = run_on("chapter", again.to_str().unwrap());
    assert_eq!(
        String::from_utf8_lossy(&before.stdout),
        String::from_utf8_lossy(&after.stdout),
        "formatting changed what the file says"
    );
    let twice = run_on("format", again.to_str().unwrap());
    assert_eq!(
        String::from_utf8_lossy(&formatted.stdout),
        String::from_utf8_lossy(&twice.stdout),
        "formatting is not stable"
    );
}

#[test]
fn a_rule_the_sentence_form_has_no_phrase_for_is_refused_by_name() {
    let ruby = write(
        "unsaid.bluebook",
        "Hecks.bluebook \"Cms\" do\n  aggregate \"Page\" do\n    identified_by :slug\n    attribute :slug, Slug\n    value_object \"Slug\" do\n      attribute :value, String\n      invariant(\"short\") { value.length < 9 }\n    end\n  end\nend\n",
    );
    let output = run_on("format", ruby.to_str().unwrap());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success());
    assert!(error.contains("no phrase for the rule `value.size < 9`"), "{error}");
}

#[test]
fn the_subcommand_for_editors_offers_the_sentences_legal_at_the_cursor() {
    let path = write(
        "cursor.bluebook",
        "Domain: Cms\n\nAggregate: Page\n  Command: Draft\n    Go",
    );
    let output = Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(["complete", path.to_str().unwrap(), "--line", "5", "--col", "7"])
        .output()
        .expect("failed to run hecks-parse");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("\"context\": \"Command\""), "{stdout}");
    assert!(stdout.contains("\"label\": \"Goal: <goal>\""), "{stdout}");
    assert!(stdout.contains("\"snippet\": \"Goal: ${1:goal}$0\""), "{stdout}");
    assert!(!stdout.contains("Aggregate:"), "{stdout}");
}

#[test]
fn an_aggregate_must_say_what_identifies_it() {
    let source = changed("  A page is identified by its slug.\n", "");
    let error = refusal("identity.bluebook", &source);
    let line = line_of(&source, "Aggregate: Page");
    assert!(error.contains(&format!("identity.bluebook:{line}:1:")), "{error}");
    assert!(error.contains("the page does not say what identifies it"), "{error}");
    assert!(error.contains("A page is identified by its <field>."), "{error}");
}

#[test]
fn a_mistyped_first_line_of_an_aggregate_is_caught_by_what_it_leaves_out() {
    let source = changed("  A page is identified by its slug.\n", "  A page is identifed by its slug.\n");
    let error = refusal("first_line.bluebook", &source);
    assert!(error.contains("does not say what identifies it"), "{error}");
}

const SEVERAL_ROLES: &str = "    Who: Editor\n    When a slug";

#[test]
fn a_command_run_by_several_roles_lowers_to_all_of_them_and_only_that_command_says_so() {
    let source = changed(SEVERAL_ROLES, "    Who: Editor or Sales Rep\n    When a slug");
    let output = parse("roles.bluebook", &source);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("\"role\": \"Editor\""), "{stdout}");
    assert!(stdout.contains("\"Sales Rep\""), "{stdout}");
    // Draft names two roles; Publish names one and emits as every command always did.
    assert_eq!(stdout.matches("\"roles\"").count(), 1, "{stdout}");
}

#[test]
fn a_role_named_twice_or_an_or_with_nothing_beside_it_is_refused() {
    let source = changed(SEVERAL_ROLES, "    Who: Editor or Editor\n    When a slug");
    let line = line_of(&source, "Editor or Editor");
    let error = refusal("roles_twice.bluebook", &source);
    assert!(error.contains(&format!("roles_twice.bluebook:{line}:10:")), "{error}");
    assert!(error.contains("a role is named twice"), "{error}");

    let trailing = changed(SEVERAL_ROLES, "    Who: Editor or\n    When a slug");
    assert!(refusal("roles_trailing.bluebook", &trailing).contains("an 'or' needs a role after it"));
}

#[test]
fn several_roles_survive_the_formatter_and_the_ruby_form() {
    let source = write(
        "roles_trip.bluebook",
        &changed(SEVERAL_ROLES, "    Who: Editor or Sales Rep\n    When a slug"),
    );
    let before = run_on("chapter", source.to_str().unwrap());
    let formatted = run_on("format", source.to_str().unwrap());
    assert!(String::from_utf8_lossy(&formatted.stdout).contains("Who: Editor or Sales Rep"));
    let again = write("roles_trip_again.bluebook", &String::from_utf8_lossy(&formatted.stdout));
    assert_eq!(
        String::from_utf8_lossy(&before.stdout),
        String::from_utf8_lossy(&run_on("chapter", again.to_str().unwrap()).stdout)
    );

    let rendered = run_on("render", source.to_str().unwrap());
    let text = String::from_utf8_lossy(&rendered.stdout).into_owned();
    assert!(text.contains("role \"Editor\", \"Sales Rep\""), "{text}");
    let ruby = write("roles_trip_ruby.bluebook", &text);
    assert_eq!(
        String::from_utf8_lossy(&before.stdout),
        String::from_utf8_lossy(&run_on("chapter", ruby.to_str().unwrap()).stdout)
    );
}

#[test]
fn a_description_that_opens_a_block_is_not_mistaken_for_prose() {
    let source = changed("  It has:\n", "  It hass:\n");
    let error = refusal("prose.bluebook", &source);
    assert!(error.contains("not a sentence I know in an aggregate"), "{error}");
    assert!(error.contains("It has:"), "{error}");
}
