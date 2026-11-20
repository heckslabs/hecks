require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/help_wanted_looks"

# What the Lead reads, and what an impediment is keyed by over every look.
RSpec.describe "HelpWanted reads" do
  include_context "with a stall watch tap"
  include HelpWantedLooks

  before { write_sources(ImpedimentLooks::STANDING) }

  it "lists a call as unassigned until the Lead assigns it", :aggregate_failures do
    raise_help
    expect(read("Unassigned").size).to eq(1)
    assign("dispatch")

    expect(read("Unassigned")).to be_empty
    expect(read("Open").size).to eq(1)
  end

  it "keys an impediment by its stall, and a fold by its kind", :aggregate_failures do
    expect(row_of("held-lock")).to include(impediment: HelpWantedLooks::HOLD)
    expect(row_of("codebase-check-failed")).to include(impediment: HelpWantedLooks::FOLD)
  end

  it "keeps a fold's key and its call when its oldest line closes and a newer one stays", :aggregate_failures do
    append("HelpWantedRaised", "help-#{HelpWantedLooks::FOLD}", "Hecks::HelpWanted", 2)
    append("FindingResolved", "gate-quick-rubocop", "Tickets::Finding", 1)

    expect(row_of("codebase-check-failed")).to include(subject: "run-77", impediment: HelpWantedLooks::FOLD)
    expect(relieved).to be_empty
  end
end
