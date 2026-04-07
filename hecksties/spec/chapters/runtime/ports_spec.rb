require "spec_helper"
require "hecks/chapters/runtime"

RSpec.describe Hecks::Chapters::Runtime::Ports do
  subject(:domain) { Hecks::Chapters::Runtime.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes port aggregates" do
    expect(names).to include("EventBus", "CommandBus", "Repository",
                             "QueryBuilder", "QueuePort")
  end

  it "CommandBus has Dispatch and AddMiddleware commands" do
    agg = domain.aggregates.find { |a| a.name == "CommandBus" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Dispatch", "AddMiddleware")
  end

  it "Repository has Create, Find, Delete commands" do
    agg = domain.aggregates.find { |a| a.name == "Repository" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Create", "Find", "Delete")
  end

  it "contributes at least 10 port aggregates" do
    port_names = %w[EventBus CommandBus CommandRunner Repository QueryBuilder
                    QueuePort CommandMixin ModelMixin QueryMixin
                    SpecificationMixin AttachmentMethods]
    present = port_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 10
  end
end
