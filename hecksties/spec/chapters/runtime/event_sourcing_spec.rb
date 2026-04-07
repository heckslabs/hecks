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

  it "includes EventSourcing namespace aggregate" do
    agg = domain.aggregates.find { |a| a.name == "EventSourcing" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Autoload")
  end

  it "contributes at least 12 event sourcing aggregates" do
    es_names = %w[EventStore SnapshotStore UpcasterRegistry UpcasterEngine
                  ProjectionRebuilder Reconstitution TimeTravel ProcessManager
                  OutboxES OutboxPoller Concurrency EventSourcing]
    present = es_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 12
  end
end
