require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/claude_jobs"

# The ids a person pinned, read for a seat to prefer; a file that cannot be read names none.
RSpec.describe Hecks::Adapters::ClaudeJobs, "#pinned_ids" do
  let(:dir) { Dir.mktmpdir }
  let(:jobs) { described_class.new(directory: dir) }

  after { FileUtils.remove_entry(dir) }

  it "names the ids in pins.json" do
    File.write(File.join(dir, "pins.json"), '["bbd18e7f"]')
    expect(jobs.pinned_ids).to eq(["bbd18e7f"])
  end

  it "names none when the file is missing" do
    expect(jobs.pinned_ids).to eq([])
  end

  it "names none when the file cannot be read" do
    File.write(File.join(dir, "pins.json"), "{oops")
    expect(jobs.pinned_ids).to eq([])
  end
end
