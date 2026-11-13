# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/git_shallow_check"

# What a shallow check's refusal reads out of a red run: the failed spec files and the message.
RSpec.describe Hecks::Adapters::GitShallowCheck::Culprit do
  # A run red in two files: a multi-line expectation, and a snapshot failure listed by id.
  let(:two_red) { File.read(File.expand_path("../../fixtures/shallow_check/two_red.txt", __dir__)) }

  def culprit(text) = described_class.new(text)

  it "names every failed spec file once, whether listed by line or by quoted id" do
    expect(culprit(two_red).specs).to eq(%w[spec/mcp_argument_policy_spec.rb spec/cli_help_snapshot_spec.rb])
  end

  it "gives the first failure's message, not the expectation's source" do
    expect(culprit(two_red).reason).to eq('["depth"] are argument names the server policy does not classify')
  end

  it "gives what was expected and what came for a one-line expectation" do
    one = two_red[two_red.index("  2) ")..]
    expect(culprit(one).reason).to eq('expected: nil got: "line 4: expected a got b"')
  end

  it "names a spec file that would not load, with the error line" do
    text = "An error occurred while loading ./spec/glossary_spec.rb.\nNameError:\n  uninitialized constant Foo\n"
    expect(culprit(text).to_s).to start_with("spec/glossary_spec.rb: NameError:")
  end

  it "bounds a long message" do
    text = "Failure/Error: expect(a).to eq(b)\n\n  #{"x" * 500}\n# ./spec/a_spec.rb:1\n"
    expect(culprit(text).reason.length).to eq(described_class::LIMIT + 3)
  end

  it "falls back to the last line a run wrote when nothing names an error" do
    expect(culprit("boot\nkilled\n").to_s).to eq("the check set: killed")
  end
end
