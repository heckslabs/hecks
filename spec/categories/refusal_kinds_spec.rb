require "spec_helper"
require "json"
require "hecks/fuzzing"

# Every domain refusal kind, raised by a real dispatch of spec/fixtures/refusal_kinds: each
# refuses with its own class, and none leaves a trace. A kind no single in-process boot can
# raise is listed in `UNREACHED_REFUSAL_KINDS` with the spec that holds it instead, so a new
# member of the DomainRefusal vocabulary fails here until it is reached or listed.
RSpec.describe "every domain refusal kind", :aggregate_failures do
  # The kinds the fixture cannot raise, each with where it is held.
  UNREACHED_REFUSAL_KINDS = {
    "AttributeAbsent"  => "needs a record saved before its attribute existed: spec/runtime/attribute_absence_spec.rb",
    "ProjectionAbsent" => "needs a projected field with no projection run yet: spec/runtime/rebuild_sweep_spec.rb",
    "RemoteRefusal"    => "raised only across a remote dispatcher, which no in-process boot has"
  }.freeze

  def self.fixture = File.join(InMemoryDomain::ROOT, "spec/fixtures/refusal_kinds")

  def self.steps = JSON.parse(File.read(File.join(fixture, "steps.json")))["steps"]

  # One replay of the fixture's steps, shared by every example; the replay boots its own copy.
  def self.history = @history ||= Hecks::Fuzzing::Replay.call(fixture, steps)

  def self.raised_kinds = history[:refusals].map { |refusal| refusal[:kind].split("::").last }

  def self.reached_kinds = (Hecks::Vocabulary.fetch("DomainRefusal") - UNREACHED_REFUSAL_KINDS.keys)

  reached_kinds.each do |kind|
    it "raises #{kind} from a real dispatch" do
      expect(self.class.raised_kinds).to include(kind)
    end
  end

  it "refuses each step with the kind it expects, in order" do
    expect(self.class.raised_kinds).to eq(self.class.steps.filter_map { |step| step["expect"] })
  end

  it "accepts each step that expects no refusal" do
    expect(self.class.history[:events].size).to eq(self.class.steps.count { |step| !step["expect"] })
  end

  it "leaves every part of the runtime as it found it after each refusal" do
    expect(Hecks::Fuzzing::Properties.refusals_leave_no_trace(self.class.history)).to be(true)
  end

  it "lists as unreached only kinds the vocabulary declares and the fixture does not raise" do
    stale = UNREACHED_REFUSAL_KINDS.keys - (Hecks::Vocabulary.fetch("DomainRefusal") - self.class.raised_kinds)
    expect(stale).to be_empty
  end
end
