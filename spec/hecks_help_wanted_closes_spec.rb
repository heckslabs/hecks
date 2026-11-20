require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/help_wanted_looks"

# A call for help closes when a look does not hold its impediment, and only then.
RSpec.describe "HelpWanted closing" do
  include_context "with a stall watch tap"
  include HelpWantedLooks

  before do
    write_sources(ImpedimentLooks::STANDING)
    raise_help
  end

  it "stays open while its impediment is in the view" do
    look("look-1")
    expect(field(:status)).to eq("open")
  end

  it "closes on the look after its impediment left the view, with that as the reason" do
    release
    look("look-1")

    expect(%i[status reason].map { |name| field(name) }).to eq(["closed", "its impediment left the view"])
  end

  it "closes once over three looks" do
    release
    3.times { |beat| look("look-#{beat}") }

    expect(events_named("HelpWantedClosed")).to eq(1)
  end
end
