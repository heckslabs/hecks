# frozen_string_literal: true

require "spec_helper"

# The model check over `creates_or_acts`: the word holds only on a creating command, on an aggregate
# whose lifecycle frees no ended id, since Ruby would archive an occupant the Rust kernel acts on.
RSpec.describe Hecks::Bluebook::ModelCheck::CreatesOrActsChecks do
  FakeVerb = Struct.new(:hecks_name, :creating) do
    def creates_or_acts? = true
    def creates? = creating
  end
  FakeLifecycle = Struct.new(:marked_states) do
    def marked(_mark) = marked_states
  end
  FakePage = Struct.new(:hecks_name, :commands, :lifecycle)

  # A one-aggregate bluebook whose one command says `creates_or_acts`.
  def bluebook(creates: true, reusable: false)
    lifecycle = reusable ? FakeLifecycle.new(["ended"]) : nil
    page = FakePage.new("Page", [FakeVerb.new("Write", creates)], lifecycle)
    instance_double(Hecks::Bluebook::Declaration, aggregates: [page])
  end

  def kinds(declaration) = Hecks::Bluebook::ModelCheck.creates_or_acts_findings(declaration).map(&:kind)

  it "reports nothing on a creating command of an aggregate that frees no id" do
    expect(kinds(bluebook)).to be_empty
  end

  it "reports a command that declares reference_to" do
    expect(kinds(bluebook(creates: false))).to eq([:misplaced_creates_or_acts])
  end

  it "reports an aggregate whose lifecycle marks ended states reusable" do
    expect(kinds(bluebook(reusable: true))).to eq([:misplaced_creates_or_acts])
  end
end
