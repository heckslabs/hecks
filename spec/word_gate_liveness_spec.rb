require "spec_helper"

# A retired or proposed grammar row must not admit its word or its `was` alias, because Rust's
# parser drops those rows (`KeywordRow::live`). These examples inject such a row into the table
# the Ruby word gate reads, so the rule is checked without a retired row in the real grammar.
RSpec.describe "Hecks::Bluebook::DSL::WordGate liveness" do
  let(:builder) { Hecks::Bluebook::DSL::AggregateBuilder.new("Box") }
  let(:grammar) { Hecks::Bluebook::MetaValidator::SyntaxBoot.call }

  def with_probe(status)
    probe = { context: "Aggregate", word: "probe_new", was: "probe_old", status: status,
              body: "none", inner: "", opens: "", fills: "", calls: "" }
    grammar.merge(keywords: grammar[:keywords] + [probe])
  end

  def admitted_by_word_gate(rows, word)
    builder.send(:word_gate_admitted, rows[:keywords], "Aggregate", word)[1]
  end

  it "refuses a retired row under its word and under its was alias", :aggregate_failures do
    rows = with_probe("retired")
    expect(admitted_by_word_gate(rows, "probe_new")).to be_empty
    expect(admitted_by_word_gate(rows, "probe_old")).to be_empty
  end

  it "refuses a proposed row under its word and under its was alias", :aggregate_failures do
    rows = with_probe("proposed")
    expect(admitted_by_word_gate(rows, "probe_new")).to be_empty
    expect(admitted_by_word_gate(rows, "probe_old")).to be_empty
  end

  it "admits a row whose status is admitted, through either spelling" do
    expect(admitted_by_word_gate(with_probe("admitted"), "probe_old")).not_to be_empty
  end

  it "still admits the deprecated then_set spelling, whose own implementation refuses it" do
    expect(builder.send(:word_gate_admitted, grammar[:keywords], "Command", "then_set")[1]).not_to be_empty
  end

  it "treats only admitted, deprecated and unset statuses as live" do
    expect(%w[admitted deprecated] + [""]).to all(satisfy { |status| Hecks::Bluebook::DSL::LiveRow.live?({ status: status }) })
  end
end
