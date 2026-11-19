require "spec_helper"

# Dispatches and reads of the decision-Point spec, over the registry its `runtime` binds.
module InterviewsDecisionAdrSteps
  # The bluebooks the spec boots together, under lib/hecks.
  BLUEBOOKS = %w[coder/coder.bluebook coder/coder.hecksagon tickets/bluebook/tickets.bluebook
                 tickets/bluebook/tickets.hecksagon interviews/interviews.bluebook
                 interviews/interviews.hecksagon].freeze

  # Loads Memory persistence, Interviews and Tickets into the registry and binds its dispatcher.
  #
  # @return [void]
  def boot_runtime
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      BLUEBOOKS.each { |file| Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks", file)) }
    end
    Hecks::Runtime::Loader.bind_runtime(dispatcher)
  end

  # Opens the spec's one interview with its first exchange.
  #
  # @return [void]
  def open_interview
    runtime
    dispatcher.dispatch_flat("Interviews::Interview.Record",
                             reference: { value: "INT-D" }, subject: { value: "tools" }, keeping: { value: "committed" },
                             speaker: { value: "owner" }, answer: { value: "Tools dissolve behind ports." })
  end

  # Proposes a Point of the given kind and accepts it, naming the record it is drafted as.
  #
  # @param number [Integer] the Point's number
  # @param kind [String] the Point's kind
  # @param said [Hash] decided_by, delegated_by and record, as the accepting turn names them
  # @return [void]
  def settle(number, kind, **said)
    point = { number: { value: number }, kind: { value: kind }, statement: { value: "Point #{number}" } }
    dispatcher.dispatch_flat("Interviews::Interview.ProposePoint", interview: "INT-D", source: { value: 1 }, **point)
    dispatcher.dispatch_flat("Interviews::Interview.Point.Accept", reference: { value: "INT-D" }, **point,
                                                                   **said.transform_values { |value| { value: value } })
  end

  # @return [Array<Array(String, String, String, Integer)>] each draft's number, title and citation
  def drafts
    Tickets::Adr.all.map { |record| [record.adr.value, record.title.value, record.interview.value, record.point.value] }
  end

  # @return [Hash] the interview's first Point, as plain data
  def first_point
    aggregate = registry.bluebook("Interviews").aggregate("Interview")
    Hecks::Runtime::Value.materialize(registry.repository("Interviews", aggregate).find("INT-D").state)[:points].first
  end
end

# ADR 0194 decision 4 and 8: an accepted decision Point is one draft decision record, and who
# decided it, delegated or not, rides the Point. Interviews and Tickets are loaded into one
# Memory registry, as attaching Interviews to the Hecks domain will boot them. The refusal
# decision 8 keeps, that no agent role takes an owner decision, is Agents' Issue
# (agents_review_and_recommendation_spec).
RSpec.describe "an accepted decision Point drafting a decision record" do
  include InterviewsDecisionAdrSteps

  let(:registry) { Hecks::Runtime::Registry.new }
  let(:runtime) { boot_runtime }
  let(:dispatcher) { Hecks::Runtime::Dispatcher.new(registry) }

  before { open_interview }

  it "drafts one decision record per accepted decision Point and none for a work Point" do
    settle(1, "decision", decided_by: "owner", record: "9301")
    settle(2, "work", decided_by: "owner")
    settle(3, "decision", decided_by: "owner", record: "9302")
    expect(drafts).to contain_exactly(["9301", "Point 1", "INT-D", 1], ["9302", "Point 3", "INT-D", 3])
  end

  it "drafts nothing for a decision Point accepted without a record number" do
    settle(1, "decision", decided_by: "owner")
    expect(drafts).to be_empty
  end

  it "refuses accepting a decision Point under a malformed record number" do
    expect { settle(1, "decision", decided_by: "owner", record: "94") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /RecordNumber.value must match/)
  end

  it "keeps who decided a delegated Point and who delegated it" do
    settle(1, "decision", decided_by: "architect", delegated_by: "owner", record: "9303")
    expect(first_point.values_at(:decided_by, :delegated_by)).to eq([{ value: "architect" }, { value: "owner" }])
  end
end
