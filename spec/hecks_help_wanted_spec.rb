require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/help_wanted_looks"

# A call for help names one impediment and the help it needs, and one stands per impediment.
RSpec.describe "HelpWanted" do
  include_context "with a stall watch tap"
  include HelpWantedLooks

  before { write_sources(ImpedimentLooks::STANDING) }

  it "holds the impediment, its age, what it holds up, the help and the role", :aggregate_failures do
    raise_help

    expect(%i[help waited holds_up kind role].map { |name| field(name) })
      .to eq(["help-#{HelpWantedLooks::HOLD}", 15, "the push train", "release-dead-holder", "orchestrator"])
    expect(field(:status)).to eq("open")
  end

  it "refuses a second call for an impediment that has one open, naming it" do
    raise_help
    expect { raise_help }.to raise_error(/help-stall-held-lock-hold-1/)
  end

  it "refuses a call whose key names no impediment" do
    wrong = call_for(HelpWantedLooks::HOLD, "coder").merge(help: { value: "help-anything" })
    expect { dispatch("Hecks::HelpWanted.Raise", **wrong) }.to raise_error(/help/)
  end
end
