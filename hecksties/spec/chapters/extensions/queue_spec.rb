# Extensions::QueueChapter paragraph spec
#
# Verifies queue internal aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::QueueChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes RabbitMqAdapter with Publish command" do
    agg = domain.aggregates.find { |a| a.name == "RabbitMqAdapter" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Publish")
  end
end
