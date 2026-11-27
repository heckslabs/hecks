//! The declared adapter's answers, read from real `.adapter` text through the parser.

use super::{answer, Outcome};
use crate::emit::JsonValue;
use crate::ir::Adapter;
use crate::{json_read, parse};

const LOOKING: &str = r#"
Hecks.adapter "ReplayedLooking" do
  port "Looking"
  replies "Look", where: { beat: "beat-quiet" }, with: { head: "4116a6d", load: 700, quiet: true, note: nil }
  replies "Look", where: { beat: "beat-storm", cores: 6 }, with: { head: "4116a6d", load: 3397 }
  refuses "Look", where: { beat: "beat-unread" }, saying: "the machine could not be read"
  replies "Post", echoing: [:pressure], with: { posted: true }
  replies "Standup", with: [{ item: "one" }, { item: "two" }]
end
"#;

fn adapter() -> Adapter {
    let mut adapters = parse::adapter::parse_file("looking.adapter", LOOKING).expect("parses");
    adapters.remove(0)
}

fn asked(text: &str) -> JsonValue {
    json_read::read(text).expect("valid JSON")
}

fn answered(ask: &str, asking: &str) -> String {
    match answer(&adapter(), ask, &asked(asking)) {
        Outcome::Answer(value) => crate::emit::write(&value)
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" "),
        Outcome::Refused(text) => format!("refused: {text}"),
    }
}

#[test]
fn the_first_row_whose_where_holds_answers_with_its_data() {
    assert_eq!(
        answered("Look", r#"{"beat": {"value": "beat-quiet"}}"#),
        r#"{ "head": "4116a6d", "load": 700, "quiet": true, "note": null }"#
    );
}

#[test]
fn a_where_compares_the_scalar_inside_a_value_object_or_a_bare_value() {
    assert_eq!(
        answered("Look", r#"{"beat": "beat-storm", "cores": {"value": 6}}"#),
        r#"{ "head": "4116a6d", "load": 3397 }"#
    );
}

#[test]
fn every_field_of_a_where_must_hold() {
    assert_eq!(
        answered("Look", r#"{"beat": "beat-storm", "cores": 4}"#),
        r#"refused: ReplayedLooking has no reply for Look where beat: "beat-storm", cores: 4"#
    );
}

#[test]
fn a_refuses_row_refuses_with_its_words() {
    assert_eq!(
        answered("Look", r#"{"beat": {"value": "beat-unread"}}"#),
        "refused: the machine could not be read"
    );
}

#[test]
fn an_ask_no_row_matches_is_refused_with_what_it_was_asked() {
    assert_eq!(
        answered("Look", r#"{"beat": {"value": "beat-new"}}"#),
        r#"refused: ReplayedLooking has no reply for Look where beat: "beat-new", cores: nothing"#
    );
}

#[test]
fn an_ask_with_no_rows_is_refused_by_name() {
    assert_eq!(
        answered("Shed", "{}"),
        "refused: ReplayedLooking declares no reply for Shed"
    );
}

#[test]
fn echoing_copies_an_asked_field_as_it_was_asked() {
    assert_eq!(
        answered(
            "Post",
            r#"{"pressure": {"value": "p-1"}, "band": "normal"}"#
        ),
        r#"{ "posted": true, "pressure": { "value": "p-1" } }"#
    );
}

#[test]
fn echoing_a_field_the_asking_lacks_is_refused() {
    assert_eq!(
        answered("Post", r#"{"band": "normal"}"#),
        "refused: Post echoes pressure, which the asking did not carry"
    );
}

#[test]
fn a_query_row_answers_with_a_list_of_rows() {
    assert_eq!(
        answered("Standup", "{}"),
        r#"[ { "item": "one" }, { "item": "two" } ]"#
    );
}

fn refusal(body: &str) -> String {
    let source = format!("Hecks.adapter \"Bad\" do\n  port \"P\"\n  {body}\nend\n");
    parse::adapter::parse_file("bad.adapter", &source)
        .err()
        .map(|diagnostic| diagnostic.message)
        .unwrap_or_default()
}

#[test]
fn a_row_that_holds_anything_but_data_is_refused_at_parse() {
    assert!(refusal(r#"replies "Look", with: { load: 1.5 }"#).contains("counts in integers"));
    assert!(refusal(r#"replies "Look", with: { band: :normal }"#).contains("with echoing:"));
    assert!(refusal(r#"replies "Look", with: { band: File.read("x") }"#).contains("not data"));
    assert!(refusal(r#"replies "Look", where: { beat: [1] }"#).contains("must equal a string"));
    assert!(refusal(r#"replies "Look", with: "text""#).contains("must be a hash"));
    assert!(refusal(r#"replies "Look", echoing: ["x"]"#).contains("as symbols"));
    assert!(
        refusal(r#"replies "Look", with: [{ a: 1 }], echoing: [:a]"#).contains("not into a list")
    );
    assert!(refusal(r#"refuses "Look""#).contains("requires 'saying:'"));
    assert!(refusal(r#"refuses "Look", saying: """#).contains("says why"));
}
