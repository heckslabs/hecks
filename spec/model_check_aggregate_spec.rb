require "spec_helper"
require "hecks/bluebook/model_check"

# An aggregate that declares more than the limit is reported, naming the commands most likely to
# belong elsewhere (ADR 0137). The check reads only what an aggregate answers, so these are plain
# structs and need no boot.
RSpec.describe Hecks::Bluebook::ModelCheck::AggregateChecks do
  let(:mutation)  { Struct.new(:op, :target) }
  let(:command)   { Struct.new(:hecks_name, :mutations) }
  let(:aggregate) { Struct.new(:hecks_name, :commands, :entities, :lifecycle, :acknowledgements) }
  let(:chapter)   { Struct.new(:aggregates) }

  def sets(*fields) = fields.map { |field| mutation.new(:set, field) }

  def sprawl(count, acknowledged = [])
    annotating = (1..count).map { |number| command.new("Annotate#{number}", sets("note", "id")) }
    aggregate.new("Sprawl", [command.new("Open", sets("id")), *annotating], [], nil, acknowledged)
  end

  def findings(count, limit, acknowledged = [])
    Hecks::Bluebook::ModelCheck.large_aggregate_findings(chapter.new([sprawl(count, acknowledged)]), limit: limit)
  end

  def acknowledging(kind)
    [Hecks::Bluebook::Acknowledgement.new(finding: kind, reason: "one ledger")]
  end

  it "reports an aggregate whose commands pass the limit", :aggregate_failures do
    found = findings(5, 3).first
    expect(found.kind).to eq(:large_aggregate)
    expect(found.severity).to eq(:warning)
    expect(found.subject).to eq("Sprawl")
  end

  it "reports nothing for an aggregate within the limit" do
    expect(findings(2, 40)).to be_empty
  end

  it "names the commands that set the fewest fields" do
    expect(findings(5, 3).first.message).to include("fewest fields are Open")
  end

  it "reports nothing for an aggregate that acknowledges the finding" do
    expect(findings(5, 3, acknowledging(:large_aggregate))).to be_empty
  end

  it "still reports an aggregate that acknowledges another kind" do
    expect(findings(5, 3, acknowledging(:other)).size).to eq(1)
  end
end
