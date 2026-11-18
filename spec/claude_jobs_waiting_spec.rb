require "spec_helper"
require "fileutils"
require "json"
require "time"
require "tmpdir"
require "hecks/hecks/adapters/claude_jobs"

# How long a blocked job has waited and whether `pins.json` names its session, read from a jobs
# directory in a temporary folder shaped as `~/.claude/jobs` is: a `state.json` whose `updatedAt`
# stamps the last write, and a `pins.json` array of eight-character job ids.
RSpec.describe Hecks::Adapters::ClaudeJobs do
  let(:dir) { Dir.mktmpdir("claude-jobs-waiting") }
  let(:jobs) { described_class.new(directory: dir) }
  let(:now) { Time.utc(2026, 11, 18, 9, 0, 0) }

  after { FileUtils.rm_rf(dir) }

  def state_file(state, stamp)
    FileUtils.mkdir_p(File.join(dir, "5e55a0a0"))
    File.write(File.join(dir, "5e55a0a0", "state.json"),
               JSON.generate(state: state, detail: "a question", updatedAt: stamp, linkScanOffset: 435_593))
    jobs.state("5e55a0a0")
  end

  def pins(text) = File.write(File.join(dir, "pins.json"), text)

  it "counts the whole minutes a blocked job has waited since its state was written" do
    expect(jobs.blocked_minutes(state_file("blocked", "2026-11-18T08:28:35.876Z"), now)).to eq(31)
  end

  it "counts nothing for a job that is not blocked" do
    expect(jobs.blocked_minutes(state_file("working", "2026-11-18T08:00:00.000Z"), now)).to eq(0)
  end

  it "counts nothing for a blocked job whose stamp cannot be read" do
    expect(jobs.blocked_minutes(state_file("blocked", "not a time"), now)).to eq(0)
  end

  it "finds no pin when there is no pins file" do
    expect(jobs.pinned?("5e55a0a0-1111-2222-3333-444455556666")).to be(false)
  end

  it "finds a session pinned by its eight-character job id" do
    pins(JSON.generate(%w[1f4544d4 5e55a0a0]))
    expect(jobs.pinned?("5e55a0a0-1111-2222-3333-444455556666")).to be(true)
  end

  it "finds a session another id is pinned for unpinned" do
    pins(JSON.generate(%w[1f4544d4]))
    expect(jobs.pinned?("5e55a0a0-1111-2222-3333-444455556666")).to be(false)
  end

  it "counts every session pinned when the pins cannot be read" do
    pins("[not json")
    expect(jobs.pinned?("5e55a0a0")).to be(true)
  end

  it "answers the minutes and the pin together" do
    job = state_file("blocked", "2026-11-18T08:50:00Z")
    expect(jobs.waiting(job, "5e55a0a0", now)).to eq(blocked_minutes: 10, pin_listed: false)
  end
end
