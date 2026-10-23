require "spec_helper"
require "json"
require "hecks/fuzzing"

# `Properties.refusals_leave_no_trace`. The pizzas corpus walks every refusal path the domain
# has, so its replay holds real refusals; the failing cases doctor one refusal's after-snapshot,
# since a runtime that leaks a refused write is what the property exists to catch.
RSpec.describe "Hecks::Fuzzing::Properties.refusals_leave_no_trace", :aggregate_failures do
  def pizzas_path = File.join(InMemoryDomain::ROOT, "examples/pizzas")

  def corpus_steps = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/pizzas.json")))["steps"]

  def verdict(history) = Hecks::Fuzzing::Properties.refusals_leave_no_trace(history)

  def corpus_history
    Hecks::Fuzzing::Replay.call(pizzas_path, corpus_steps).tap do |history|
      expect(history[:refusal_traces]).not_to be_empty
    end
  end

  # The history with its first refusal's after-snapshot changed in `part`.
  def doctored(history, part, value)
    first, *rest = history[:refusal_traces]
    history.merge(refusal_traces: [first.merge(after: first[:after].merge(part => value)), *rest])
  end

  it "passes a history with no refusals" do
    expect(verdict(refusal_traces: [])).to be(true)
  end

  it "passes the pizzas corpus, whose refusals each leave the runtime as they found it" do
    expect(verdict(corpus_history)).to be(true)
  end

  Hecks::Fuzzing::Properties::Refusals::REFUSAL_TRACE_PARTS.each do |part|
    it "names a refusal that changed its #{part}" do
      expect(verdict(doctored(corpus_history, part, :changed))).to be_a(String).and include("refused", "changed #{part}")
    end
  end

  it "skips an entry missing either snapshot" do
    expect(verdict(refusal_traces: [{ verb: "Pizzas::Order.Purchase", kind: "GivenNotMet", before: {} }])).to be(true)
  end
end
