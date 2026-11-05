require "spec_helper"

# The reviewer's judgment of a failing spec, the release manager's recommendation, and the rule that
# no role issues an owner decision. Booted in Memory, one registry per example.
RSpec.describe "the Agents reviewer, recommendation and owner-only rule" do
  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  def boot_agents
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  before { boot_agents }

  let(:review) { Hecks::Agents::SubmissionReview }

  def request(hops) = review.request!(work: { value: "w1" }, hops: { value: hops })

  it "accepts a review request under the hop limit" do
    expect { request(2) }.not_to raise_error
  end

  it "refuses a review request at the hop limit, by name" do
    expect { request(3) }.to raise_error(Hecks::Runtime::GivenNotMet, /under the hop limit/)
  end

  it "records a judgment the reviewer gives" do
    expect { request(1).judge!(judgment: { value: "stale_expectation" }) }.not_to raise_error
  end

  it "refuses a judgment the reviewer does not give, by name" do
    expect { request(1).judge!(judgment: { value: "shrug" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /judgment is one the reviewer gives/)
  end

  it "records a promotion recommendation without promoting" do
    expect do
      Hecks::Agents::PromotionRecommendation.recommend!(commit: { value: "c841f1d" }, reasons: { value: "green" })
    end.not_to raise_error
  end

  it "refuses a role issuing an owner decision, by name" do
    role = Hecks::Agents::Role.declare!(name: { value: "release_manager" }, kind: { value: "release_manager" })
    expect { role.issue!(command: { value: "promote" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /not an owner decision/)
  end
end
