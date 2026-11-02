require "spec_helper"
require "tmpdir"
require "hecks/projector"

# Narrate tells each goal an `.examples` file declares as a use case (ADR 0173): the goal, its main
# scenario and its extensions, every line quoted from the file.
RSpec.describe Hecks::Projector::NarrateProjector::UseCases do
  SHOP_EXAMPLES = File.expand_path("fixtures/sentence_examples/shop/shop.examples", __dir__) unless defined?(SHOP_EXAMPLES)

  def narrated(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.examples")
      File.write(path, text)
      described_class.narrative([path], 2)
    end
  end

  it "tells the shop's goal with its main scenario first and its extensions after", :aggregate_failures do
    text = described_class.narrative([SHOP_EXAMPLES], 2)
    expect(text).to start_with("## Use cases\n\n### Remy serves a pizza someone ordered")
    expect(text).to include("**Main scenario: A topping goes on a pizza before the order is closed**\n- Given Remy creates")
    expect(text).to include("**Extension: A closed order cannot be closed again**")
  end

  it "leaves out an example that stands outside every goal" do
    expect(described_class.narrative([SHOP_EXAMPLES], 2)).not_to include("Only a chef puts a topping on")
  end

  it "says nothing when no file declares a goal" do
    expect(narrated("Examples for: Shop\n\nExample: One\n  When Remy closes it\n")).to be_nil
  end

  it "joins the bluebook's narrative when narrate is given the examples" do
    bluebook = Hecks::Bluebook::DSL::BluebookBuilder.build("Shop") { aggregate("Order") { identified_by :id } }
    told = Hecks::Projector.call(:narrate, bluebook: bluebook, options: { examples: [SHOP_EXAMPLES] })
    expect(told).to include("## Use cases")
  end
end
