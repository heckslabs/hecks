require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_settled_looks"

# Stall checks do not multiply: none is filed about a stall item or a stall session's landing, and
# a second look files no second item.
RSpec.describe "StallWatch about stall items and second looks" do
  include_context "with a stall watch tap"
  include StallSettledLooks

  it "files no stall about a stall session's own landing" do
    carry("landing-1", "stall-agent-run-session-w1")

    expect(stalls).to be_empty
  end

  it "refuses to file a stall whose subject is a stall item" do
    expect { file_about_a_stall_item }.to raise_error(Hecks::Runtime::GivenNotMet, /not about a stall item/)
  end

  it "plans one work item however many looks see the same stall" do
    started("w1")
    detect("look-1")
    detect("look-2")

    expect(keys("Tickets", "Work", :work)).to eq(%w[stall-agent-run-session-w1])
  end
end
