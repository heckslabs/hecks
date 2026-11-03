require "spec_helper"

# A policy declared `root` is a reaction that is never refused at the reaction depth cap: it runs
# its target at depth zero and restores the cascade's depth when it returns. A fault report uses it,
# so a gate run that faults deep inside another cascade still files its finding.
RSpec.describe "root policies" do
  def built(&block)
    Hecks::Bluebook::DSL::PolicyBuilder.build("Report", &block)
  end

  it "builds a policy declared root, and a plain one as not root" do
    expect(built { on "Thing.Broke"; root; across "Tickets" }.root).to be(true)
    expect(built { on "Thing.Broke"; across "Tickets" }.root).to be(false)
  end

  describe Hecks::Runtime::Dispatcher do
    let(:dispatcher) { described_class.allocate }
    let(:cap) { described_class::MAX_REACTION_DEPTH }

    around do |example|
      previous = Thread.current[:hecks_reaction_depth]
      example.run
    ensure
      Thread.current[:hecks_reaction_depth] = previous
    end

    it "runs a root reaction at depth zero and restores the cascade's depth" do
      Thread.current[:hecks_reaction_depth] = cap
      seen = nil
      allow(dispatcher).to receive(:dispatch_flat) { seen = Thread.current[:hecks_reaction_depth] }

      dispatcher.reenter_root("Tickets::Finding.ReportFailedRun", run: "r1")

      expect(seen).to eq(0)
      expect(Thread.current[:hecks_reaction_depth]).to eq(cap)
    end

    it "leaves an ordinary reaction at the cap refused by the caller's check, not by reenter_root" do
      Thread.current[:hecks_reaction_depth] = cap
      expect(dispatcher.reaction_depth_reached?).to be(true)
    end
  end
end
