require "spec_helper"

# An architect job launches with its plan as the brief or not at all: a dispatch whose brief says
# nothing is refused by the bluebook before any session is started.
RSpec.describe "an architect job with no plan text" do
  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  def dispatch(brief)
    @hecks.dispatch_flat("Hecks::AgentRun.Dispatch", run: "architect-no-plan", agent: "architect", brief: brief)
  end

  it "refuses and launches nothing", :aggregate_failures do
    allow(Open3).to receive(:popen3)

    expect { dispatch("   ") }.to raise_error(Hecks::Runtime::GivenNotMet, /a brief says something/)
    expect(Open3).not_to have_received(:popen3)
  end
end
