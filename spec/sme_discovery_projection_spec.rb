require "spec_helper"
require "hecks"
require "hecks/sme/discovery_projection"

# The discovery projection (ADR 0194, decisions 4 and 10): an interview's accepted discovery
# Points become bluebook text, every line citing its Point and exchange, and the text is checked
# by `model_check` staged in a temporary directory.
module DiscoveryProjectionSpec
  # A Point in the shape of the Interviews bluebook's.
  def self.point(number, kind, statement, status: "accepted", source: 1)
    { number: number, kind: kind, statement: statement, source: source, status: status }
  end

  # Order with an action and a field, and a rule beside it.
  SHOP = [point(1, "thing", "Order"), point(2, "action", "Order: Place -> Placed", source: 2),
          point(3, "field", "Order: total", source: 2),
          point(4, "rule", "An order needs a total", source: 3)].freeze

  # Points that are not accepted, or not of a discovery kind.
  UNPROJECTED = [point(1, "thing", "Ghost", status: "proposed"), point(2, "thing", "Gone", status: "rejected"),
                 point(3, "thing", "Old", status: "superseded"), point(4, "work", "Build"),
                 point(5, "decision", "Mem")].freeze

  # Statements the grammar cannot place: an action on no accepted thing, a thing of two words.
  UNREAD = [point(1, "action", "Customer: Pay -> Paid"), point(2, "thing", "Line item")].freeze
end

RSpec.describe Hecks::SME::DiscoveryProjection do
  let(:points) { DiscoveryProjectionSpec::SHOP }
  let(:text) { described_class.text(subject: "Shop floor", points: points) }

  it "renders an accepted thing as an aggregate citing its Point" do
    expect(text).to include(%(  # thing, point 1 (exchange 1)\n  aggregate "Order" do))
  end

  it "renders an accepted action as a command emitting the event it names" do
    expect(text).to match(/# action, point 2 \(exchange 2\)\n    command "Place" do.*emits "Placed"/m)
  end

  it "renders an accepted field as an attribute of its thing" do
    expect(text).to include("# field, point 3 (exchange 2)\n    attribute :total, Total")
  end

  it "keeps a rule as a comment citing its exchange, never as code" do
    expect(text).to include("  # rule, point 4 (exchange 3): An order needs a total")
  end

  it "names the bluebook from the subject" do
    expect(text).to start_with(%(Hecks.bluebook "ShopFloor" do))
  end

  context "with Points proposed, rejected or superseded, or of kind work or decision" do
    let(:points) { DiscoveryProjectionSpec::UNPROJECTED }

    it "projects none of them" do
      expect(text).not_to match(/Ghost|Gone|Old|Build|Mem/)
    end
  end

  context "with statements the grammar cannot place" do
    let(:points) { DiscoveryProjectionSpec::UNREAD }

    it "keeps each as a cited comment and guesses no code", :aggregate_failures do
      expect(text).to include("# action, point 1 (exchange 1): Customer: Pay -> Paid")
      expect(text).to include("# thing, point 2 (exchange 1): Line item")
      expect(text).not_to match(/command "Pay"|aggregate "Line/)
    end
  end

  describe ".check" do
    it "stages the projection and model_check finds it clean", :aggregate_failures do
      verdict = described_class.check(subject: "Shop", points: points)[:verdict]
      expect(verdict.report).to include("No dead states")
      expect(verdict.clean).to be(true)
    end

    it "is not clean, and names the finding, when the text references no declared aggregate", :aggregate_failures do
      verdict = described_class::StagedCheck.call(text.sub("attribute :total, Total", "reference_to Ghost"))
      expect(verdict.report).to match(/no Aggregate with bluebook.*ShopFloor:Ghost/)
      expect(verdict.clean).to be(false)
    end

    it "is not clean, and says why, when the staged text is not Ruby", :aggregate_failures do
      verdict = described_class::StagedCheck.call(%(Hecks.bluebook "Broken" do\n))
      expect(verdict.report).to start_with("SyntaxError")
      expect(verdict.clean).to be(false)
    end
  end
end
