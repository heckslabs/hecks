require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/stall_watching"

# The `slots` evidence read names who holds each heavy-job slot and when its lock last changed hands.
RSpec.describe Hecks::Adapters::StallWatching::SlotEvidence do
  let(:dir) { Dir.mktmpdir("hecks-slots") }

  after { FileUtils.remove_entry(dir) }

  it "names the holder of a slot and when its lock last changed hands", :aggregate_failures do
    File.write(File.join(dir, "slot-0.lock"), "gate 42")
    File.utime(Time.now - 600, Time.now - 600, File.join(dir, "slot-0.lock"))

    expect(described_class.new(dir: dir).line).to include("slot-0 held by gate 42", "changed 10 min ago")
  end

  it "answers nothing when the machine keeps no slot" do
    expect(described_class.new(dir: dir).line).to be_nil
  end
end
