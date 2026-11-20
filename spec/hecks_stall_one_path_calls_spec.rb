require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_one_path_looks"

# A call for help is taken only for a stall a call clears, so no stall holds both paths.
RSpec.describe "A call for help and a stall item" do
  include_context "with a stall watch tap"
  include StallOnePathLooks

  before { write_sources(StallOnePathLooks::SOURCES) }

  it "takes a call for the stall a call clears" do
    raise_help
    expect(field(:status)).to eq("open")
  end

  it "refuses a call for a stall its stall item clears" do
    expect { raise_help_as(StallOnePathLooks::BLOCK, "item") }.to raise_error(/its stall item clears gets no call for help/)
  end

  it "gives each stall one path, never both" do
    look_and_tap("look-1")
    raise_help

    expect(paths_held).to eq([1, 1])
  end

  it "relieves a call that stands for a stall its stall item clears" do
    append("HelpWantedRaised", "help-#{StallOnePathLooks::BLOCK}", "Hecks::HelpWanted", 0)
    expect(relieved_rows).to eq([{ help: "help-#{StallOnePathLooks::BLOCK}", reason: "its stall item clears it" }])
  end
end
