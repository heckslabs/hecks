require "spec_helper"

# A started work item whose session was declined holds a place for nothing: the Tickets bluebook
# yields it at once with the refusal, instead of leaving it to the start window's settle.
RSpec.describe "a work item whose run is declined" do
  let(:policy) do
    Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/bluebook")).registry.bluebooks
         .fetch("Tickets").policies.find { |candidate| candidate.name == "YieldWhenItsRunIsDeclined" }
  end

  it "is yielded by the policy that reacts to the declined run, keyed by the work item" do
    expect([policy.on_event, policy.trigger_command]).to eq(%w[AgentRun.AgentRunDeclined Work.Yield])
  end

  it "carries the refusal as the reason, and the run's key as the work item", :aggregate_failures do
    expect(policy.with_spec.to_h.transform_keys(&:to_sym)).to include(work: :run, reason: :refusal)
  end
end
