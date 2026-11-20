# frozen_string_literal: true

require "spec_helper"
require_relative "support/probe_window"

# A turn of a setting is watched for its window: the pipeline over the two hours before it is the
# baseline, and once the window ends the machine's beat reads it again. A turn after which starts
# or landings fell by half is turned back to what it was; one the pipeline held through is kept;
# one turned with probe false is not watched. The event log is a scratch file and the domain is in
# Memory.
RSpec.describe "a probe of a turned setting" do
  include ProbeWindow

  it "turns a setting back once the window after it saw no starts" do
    expect(status(probed([logged("BranchLanded", "b9", turned_at + 900)]))).to eq("reverted")
  end

  it "sets the setting back to what it was before the turn" do
    probed([])
    expect(turning.restored).to eq([{ setting: { value: "admission.signalbox" }, before: { value: "false" } }])
  end

  it "keeps a turn the pipeline held through" do
    starts = (1..3).map { |n| logged("WorkStarted", "s#{n}", turned_at + (n * 300)) }
    expect(status(probed(starts + [logged("BranchLanded", "b9", turned_at + 900)]))).to eq("kept")
  end

  it "judges nothing before the window has ended" do
    expect(status(probed([], after: 600))).to eq("watching")
  end

  it "opens no probe for a turn with probe false" do
    expect(probed([], probe: false)).to be_nil
  end
end
