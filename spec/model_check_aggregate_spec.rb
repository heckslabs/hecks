require "spec_helper"
require "hecks/bluebook/model_check"

# An aggregate that declares more than the limit is reported, naming the commands most likely to
# belong elsewhere (ADR 0137).
RSpec.describe Hecks::Bluebook::ModelCheck::AggregateChecks do
  def bluebook_with(command_count)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      declare_sprawl(command_count)
    end
    registry.bluebook("ChkSize")
  end

  def declare_sprawl(command_count)
    Hecks.bluebook "ChkSize" do
      aggregate "Sprawl" do
        identified_by :id
        attribute :id, Id
        attribute :note, Note

        value_object "Id" do
          attribute :value, String
        end

        value_object "Note" do
          attribute :value, String
        end

        command "Open" do
          goal "open it"
          attribute :id, Id
          sets :id
        end

        (1..command_count).each do |number|
          command "Annotate#{number}" do
            goal "annotate it"
            attribute :id, Id
            attribute :note, Note
            sets :note
          end
        end
      end
    end
  end

  def findings(count, limit)
    Hecks::Bluebook::ModelCheck.large_aggregate_findings(bluebook_with(count), limit: limit)
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
end
