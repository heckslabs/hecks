require "spec_helper"
require "hecks/chapters/runtime"

RSpec.describe Hecks::Chapters::Runtime::PortInternals do
  subject(:domain) { Hecks::Chapters::Runtime.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes command and collection aggregates" do
    expect(names).to include("CommandMethods", "CommandResolver",
                             "CollectionItem", "CollectionMethods",
                             "CollectionProxy")
  end

  it "includes event and repository aggregates" do
    expect(names).to include("EventRecorder", "ReferenceMethods",
                             "RepositoryMethods")
  end

  it "includes outbox and queue aggregates" do
    expect(names).to include("MemoryOutbox", "MemoryQueue")
  end

  it "includes query aggregates" do
    expect(names).to include("AdHocQueries", "ConditionNode",
                             "InMemoryExecutor", "ScopeMethods")
  end

  it "includes operator aggregates" do
    expect(names).to include("Operators", "Operator", "Gt", "Gte", "Lt",
                             "Lte", "In", "NotEq")
  end

  it "RepositoryMethods has CRUD commands" do
    agg = domain.aggregates.find { |a| a.name == "RepositoryMethods" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Create", "Read", "Update", "Delete")
  end

  it "contributes at least 22 port internal aggregates" do
    pi_names = %w[CommandMethods CommandResolver CollectionItem
                  CollectionMethods CollectionProxy EventRecorder
                  ReferenceMethods RepositoryMethods MemoryOutbox
                  MemoryQueue AdHocQueries ConditionNode InMemoryExecutor
                  ScopeMethods Operators Operator Gt Gte Lt
                  Lte In NotEq]
    present = pi_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 22
  end
end
