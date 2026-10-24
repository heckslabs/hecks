require "spec_helper"
require "hecks/fuzzing"

# A bulk run's per-row outcomes, and the records it leaves, equal dispatching each row by hand
# (ADR 0121). The property replays one generated history twice and compares the two after every
# command-and-query pair Banking declares.
RSpec.describe "Fuzzing::Properties.bulk_runs_match_hand_dispatch" do
  let(:banking) { File.join(InMemoryDomain::ROOT, "examples/banking") }
  let(:steps)   { Hecks::Fuzzing::SequenceGenerator.generate(banking, seed: 3, steps: 40, adapter: :memory) }

  def parity = Hecks::Fuzzing::Properties.bulk_runs_match_hand_dispatch(banking, steps)

  it "holds for a generated Banking history" do
    expect(parity).to be(true)
  end

  it "names the pair when a bulk run skips a row dispatching by hand would reach" do
    allow(Hecks::Bulk::Sweep).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |sweep| allow(sweep).to receive(:outcomes).and_return([]) }
    end
    expect(parity).to match(/over Banking::.*a bulk run answered \[\]/)
  end

  it "does not apply to a domain that does not attach Bulk" do
    pizzas = File.join(InMemoryDomain::ROOT, "examples/pizzas")
    expect(Hecks::Fuzzing::Properties.bulk_runs_match_hand_dispatch(pizzas, [])).to be(true)
  end
end
