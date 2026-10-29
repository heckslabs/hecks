require "spec_helper"
require "hecks/bluebook/model_check"

# An aggregate with no commands is reported as an error: nothing changes it, and a command surface
# diagram has nothing to draw. The check reads only what an aggregate answers, so these are plain
# structs and need no boot.
RSpec.describe Hecks::Bluebook::ModelCheck::AggregateChecks do
  let(:aggregate)   { Struct.new(:hecks_name, :commands, :acknowledgements) }
  let(:declaration) { Struct.new(:aggregates) }
  let(:command)     { Struct.new(:hecks_name).new("Plant") }

  def findings(*aggregates)
    Hecks::Bluebook::ModelCheck.no_command_surface_findings(declaration.new(aggregates))
  end

  def acknowledging(kind)
    [Hecks::Bluebook::Acknowledgement.new(finding: kind, reason: "read-only by design")]
  end

  it "reports an aggregate with no commands as an error", :aggregate_failures do
    found = findings(aggregate.new("Cognition", [], [])).first
    expect(found.kind).to eq(:no_command_surface)
    expect(found.severity).to eq(:error)
    expect(found.subject).to eq("Cognition")
  end

  it "reports nothing for an aggregate with a command" do
    expect(findings(aggregate.new("Seed", [command], []))).to be_empty
  end

  it "reports each commandless aggregate once" do
    found = findings(aggregate.new("Cognition", [], []), aggregate.new("Seed", [command], []),
                     aggregate.new("Prompt", [], []))
    expect(found.map(&:subject)).to eq(%w[Cognition Prompt])
  end

  it "reports nothing for a commandless aggregate that acknowledges the finding" do
    expect(findings(aggregate.new("Route", [], acknowledging(:no_command_surface)))).to be_empty
  end

  it "still reports a commandless aggregate that acknowledges another kind" do
    expect(findings(aggregate.new("Route", [], acknowledging(:large_aggregate))).size).to eq(1)
  end
end
