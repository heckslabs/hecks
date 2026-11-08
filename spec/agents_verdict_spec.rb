require "spec_helper"

# Boots the Agents bluebook in Memory with its own registry.
module AgentsVerdictBoot
  def self.call
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(InMemoryDomain::ROOT, "lib/hecks/agents/agents.bluebook")].each do |file|
        Kernel.load(file)
      end
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end
end

# A judge's verdict is a command on the change: judged with no PlanReview row at all, then delivered
# to the waiting coder or recorded undeliverable with the reason. Booted in Memory, one registry per run.
RSpec.describe "the Agents verdict delivery" do
  before { AgentsVerdictBoot.call }

  def judge(role: "architect", answer: "changes: six")
    Hecks::Agents::Verdict.judge!(run: { value: "r1" }, work: { value: "w1" }, role: { value: role },
                                  answer: { value: answer })
  end

  it "judges an architect's verdict with no PlanReview row" do
    expect(judge.status).to eq("judged")
  end

  it "judges a reviewer's verdict" do
    expect(judge(role: "reviewer", answer: "stale_expectation").role.value).to eq("reviewer")
  end

  it "refuses a judge that is neither architect nor reviewer, by name" do
    expect { judge(role: "coder") }.to raise_error(Hecks::Runtime::GivenNotMet, /architect or the reviewer/)
  end

  it "records a verdict delivered to the coder" do
    expect(judge.deliver!.status).to eq("delivered")
  end

  it "records why a verdict could not be delivered" do
    expect(judge.undeliver!(reason: { value: "no waiting coder" }).status).to eq("undeliverable")
  end
end
