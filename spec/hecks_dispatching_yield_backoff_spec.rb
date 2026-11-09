require "spec_helper"
require "time"
require "hecks/hecks/adapters/dispatching"

# A work item that fails again and again backs off longer each time, because the item carries how
# many times it has yielded. The launcher's commands are answered by a stand-in runner.
RSpec.describe Hecks::Adapters::Dispatching::Launcher, "#yield_back" do
  let(:calls) { [] }
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }

  def done = Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, success?: true))

  def item(count)
    Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: [], yield_count: count)
  end

  def launcher = described_class.new("/repo", runner: ->(argv) { (calls << argv) && done })

  def yielded(count)
    calls.clear
    launcher.yield_back(item(count), "its session ended failed", now: now)
    calls.last
  end

  def retry_in(count)
    word = yielded(count).find { |argument| argument.start_with?("retry_at.value=") }
    Time.iso8601(word.split("=", 2).last) - now
  end

  it "counts one more than the work item has yielded", :aggregate_failures do
    expect(yielded(0)).to include("yield_count.value=1")
    expect(yielded(2)).to include("yield_count.value=3")
  end

  it "waits 5, 15 and then 45 minutes across repeated failures" do
    expect([0, 1, 2, 3].map { |count| retry_in(count) }).to eq([300, 900, 2700, 2700])
  end

  it "counts a bare key as a first yield" do
    launcher.yield_back("a", "its session ended failed", now: now)

    expect(calls.last).to include("yield_count.value=1")
  end
end
