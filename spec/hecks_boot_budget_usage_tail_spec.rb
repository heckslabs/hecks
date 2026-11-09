require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"

# The reader of the usage record's tail: a bounded read from the end that stops at the first run
# older than the window.
RSpec.describe Hecks::Adapters::BootBudget::UsageTail do
  let(:cutoff) { Time.utc(2026, 11, 9, 0, 0, 0) }

  def line(minutes, boot_ms = 10)
    at = (cutoff + (minutes * 60)).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    %({"boot_ms":#{boot_ms},"at":"#{at}"}\n)
  end

  def tail_of(text, **constants)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "usage.jsonl")
      File.write(path, text)
      constants.each { |name, value| stub_const("#{described_class}::#{name}", value) }
      described_class.since(cutoff, path: path)
    end
  end

  it "answers the runs of the window, newest first, and stops at the first older one", :aggregate_failures do
    rows = tail_of([line(-90), %({"date":"2026-11-08"}\n), line(-30), line(10), line(20)].join)

    expect(rows.map { |row| row["at"] }).to eq(%w[2026-11-09T00:20:00Z 2026-11-09T00:10:00Z])
  end

  it "skips a torn last line instead of failing" do
    rows = tail_of([line(10), line(20), %({"boot_ms":1,"at":"2026)].join)

    expect(rows.size).to eq(2)
  end

  it "reads no more than its limit from the end, whatever the file holds", :aggregate_failures do
    rows = tail_of(Array.new(300) { |n| line(n + 1) }.join, LIMIT: 600, CHUNK: 128)

    expect(rows.size).to be_between(1, 14)
    expect(rows.first["at"]).to eq("2026-11-09T05:00:00Z")
  end

  it "answers nothing for a record that is not there" do
    expect(described_class.since(cutoff, path: "/nonexistent/usage.jsonl")).to eq([])
  end
end
