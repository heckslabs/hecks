require "spec_helper"
require "hecks/chapters/runtime"

RSpec.describe Hecks::Chapters::Runtime::EventSourcingChapter do
  subject(:domain) { Hecks::Chapters::Runtime.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes event sourcing aggregates" do
    expect(names).to include("EventStore", "SnapshotStore", "Reconstitution",
                             "TimeTravel", "ProcessManager")
  end

  it "EventStore has Append and ReadStream commands" do
    agg = domain.aggregates.find { |a| a.name == "EventStore" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Append", "ReadStream")
  end

  it "UpcasterRegistry has Register command" do
    agg = domain.aggregates.find { |a| a.name == "UpcasterRegistry" }
    expect(agg.commands.map(&:name)).to include("Register")
  end

  it "contributes at least 10 event sourcing aggregates" do
    es_names = %w[EventStore SnapshotStore UpcasterRegistry UpcasterEngine
                  ProjectionRebuilder Reconstitution TimeTravel ProcessManager
                  OutboxES OutboxPoller Concurrency]
    present = es_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 10
  end
end
