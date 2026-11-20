require "spec_helper"
require "hecks/hecks/adapters/reviewer_judgment"

# The reviewer's judgment of a submission, and the rule that no role issues an owner decision.
# Booted in Memory, one registry per example.
RSpec.describe "the Agents reviewer and owner-only rule" do
  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  def boot_agents
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    @dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    Hecks::Runtime::Loader.bind_runtime(@dispatcher)
  end

  def fired
    @dispatcher.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.map(&:to_s)
  end

  before { boot_agents }

  let(:review) { Hecks::Agents::SubmissionReview }

  def request(hops, commit = "c1")
    review.request!(submission: { value: commit }, work: { value: "w1" }, hops: { value: hops },
                    role: { value: "reviewer" }, repo: { value: "/tmp" }, brief: { value: "w1" })
  end

  it "accepts a review request under the hop limit" do
    expect { request(2) }.not_to raise_error
  end

  it "refuses a review request at the hop limit, by name" do
    expect { request(3) }.to raise_error(Hecks::Runtime::GivenNotMet, /under the hop limit/)
  end

  it "records a judgment the reviewer gives" do
    expect { request(1).judge!(judgment: { value: "stale_expectation" }) }.not_to raise_error
  end

  # `clean` is left out: it also needs a full tier and its evidence, which other examples show.
  it "records every closing word the reviewer's adapter reads, with the findings a missing behavior names" do
    words = Hecks::Adapters::ReviewerJudgment::WORDS - ["clean"]
    judge = ->(word, i) { request(1, "c-#{i}").judge!(judgment: { value: word }, findings: { value: "the scenario" }) }
    expect { words.each_with_index(&judge) }.not_to raise_error
  end

  it "refuses a judgment the reviewer does not give, by name" do
    expect { request(1).judge!(judgment: { value: "shrug" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /judgment is one the reviewer gives/)
  end

  it "hands a real bug to a person, and a stale expectation to no one", :aggregate_failures do
    request(1, "w-stale").judge!(judgment: { value: "stale_expectation" })
    expect(fired).not_to include(a_string_ending_with("HandedToPerson"))
    request(1, "w-bug").judge!(judgment: { value: "real_bug" })
    expect(fired).to include(a_string_ending_with("HandedToPerson"))
  end

  it "ends a review whose branch landed before it ran, handing nothing to a person" do
    request(1, "w-landed").judge!(judgment: { value: "landed" })
    expect(fired).not_to include(a_string_ending_with("HandedToPerson"))
  end

  it "refuses a role issuing an owner decision, by name" do
    role = Hecks::Agents::Role.declare!(name: { value: "reviewer" }, kind: { value: "reviewer" })
    expect { role.issue!(command: { value: "promote" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /not an owner decision/)
  end
end
