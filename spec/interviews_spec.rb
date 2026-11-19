require "spec_helper"

# Dispatches and reads of the Interviews spec, over the runtime its `hecks` boots.
module InterviewsSpecSteps
  # Opens the spec's one interview with its first exchange.
  #
  # @return [Hecks::Runtime::Dispatcher::Result] the dispatch's result
  def open_interview
    hecks.dispatch_flat("Interviews::Interview.Record",
                        reference: { value: "INT-1" }, subject: { value: "tools" }, keeping: { value: "committed" },
                        speaker: { value: "owner" }, answer: { value: "Tools dissolve behind ports." })
  end

  # Proposes a `work` Point on that interview, citing its first exchange.
  #
  # @param number [Integer] the Point's number
  # @return [Hecks::Runtime::Dispatcher::Result] the dispatch's result
  def propose(number)
    hecks.dispatch_flat("Interviews::Interview.ProposePoint",
                        interview: "INT-1", number: { value: number }, kind: { value: "work" },
                        statement: { value: "Move tool #{number}" }, source: { value: 1 })
  end

  # @return [Hash] the interview's stored state, as plain data
  def interview
    aggregate = hecks.registry.bluebook("Interviews").aggregate("Interview")
    Hecks::Runtime::Value.materialize(hecks.registry.repository("Interviews", aggregate).find("INT-1").state)
  end

  # @return [Hash] the first PointAccepted event's payload, as plain data
  def accepted
    event = hecks.registry.event_log.find { |entry| entry.name == "PointAccepted" }
    Hecks::Runtime::Value.materialize(event.payload)
  end
end

# The Interviews bluebook (ADR 0194), booted from lib/hecks/interviews in Memory: what an
# accepted Point announces, and that writers appending to one interview at once lose nothing.
# The Point lifecycle and the conclusion rules are its `.behaviors` file's examples.
RSpec.describe "the Interviews bluebook" do
  include InterviewsSpecSteps

  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/interviews"), install_driving: false) }

  before { open_interview }

  it "announces an accepted point with its kind and statement" do
    propose(1)
    hecks.dispatch_flat("Interviews::Interview.Point.Accept", reference: { value: "INT-1" }, number: { value: 1 },
                                                              kind: { value: "work" }, statement: { value: "Move tool 1" })
    expect(accepted).to include(kind: { value: "work" }, statement: { value: "Move tool 1" })
  end

  # Memory holds no version to compare, so ADR 0035's per-record lock serializes the writers: each
  # reads the interview the other left, and neither append nor count is lost.
  it "keeps every point and count when eight writers propose at once" do
    (1..8).map { |number| Thread.new { propose(number) } }.each(&:join)
    expect([interview[:points].size, interview[:open_points]]).to eq([8, { value: 8 }])
  end
end
