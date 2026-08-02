//! `sets` is the word; `then_set` is the spelling every existing bluebook
//! was written under — Syntax::Keyword carries the rename as `was:`, and
//! the contract of that column is that BOTH spellings parse, forever, to
//! byte-identical IR. The Ruby twin of this test lives in spec/dsl_spec.rb
//! ("builds the same mutation under sets and then_set — a rename, not a
//! fork"); this is the same claim made against this parser.

use storehouse::parser;

fn bluebook_with(mutation_line: &str) -> String {
    format!(
        r#"Hecks.bluebook "Spelled" do
  aggregate "Thing" do
    identified_by {{ name.value }}
    attribute :name, Name
    attribute :count, Tally

    value_object "Name" do
      attribute :value, String
    end

    value_object "Tally" do
      attribute :value, Integer
    end

    command "Bump" do
      attribute :amount, Tally
      {mutation_line}
      emits "Bumped"
    end
  end
end
"#
    )
}

#[test]
fn sets_and_then_set_build_identical_mutations() {
    let renamed = parser::parse(&bluebook_with("sets :count, increment: :amount"));
    let original = parser::parse(&bluebook_with("then_set :count, increment: :amount"));

    let renamed_cmd = &renamed.aggregates[0].commands[0];
    let original_cmd = &original.aggregates[0].commands[0];

    assert_eq!(renamed_cmd.mutations.len(), 1, "sets parsed no mutation");
    assert_eq!(
        format!("{:?}", renamed_cmd.mutations),
        format!("{:?}", original_cmd.mutations),
        "the two spellings built different IR — the rename column is lying"
    );
}
