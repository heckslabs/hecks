# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/runtime/event_feed"

# A line with no sequence number (written by a checkout that predates numbering) is counted, not
# returned as an event and not passed over by the cursor.
RSpec.describe Hecks::Runtime::EventFeed, "#read with unnumbered lines" do
  let(:dir) { Dir.mktmpdir("feed-unnumbered") }
  let(:path) { File.join(dir, "events.jsonl") }
  let(:feed) { described_class.new(path: path) }

  after { FileUtils.rm_rf(dir) }

  def numbered(seq, name)
    JSON.generate("kind" => "event", "aggregate" => "Hecks::Thing", "event" => name, "seq" => seq)
  end

  def unnumbered(name) = JSON.generate("kind" => "event", "event" => name)

  def write_lines(*lines) = File.write(path, lines.map { |text| "#{text}\n" }.join)

  it "returns the numbered events and counts the unnumbered line" do
    write_lines(numbered(1, "First"), unnumbered("Unnumbered"), numbered(2, "Second"))
    result = feed.read

    expect(result[:events].map { |event| event["event"] }).to eq(%w[First Second])
  end

  it "counts the unnumbered line" do
    write_lines(numbered(1, "First"), unnumbered("Unnumbered"), numbered(2, "Second"))

    expect(feed.read[:unnumbered]).to eq(1)
  end

  it "does not move the cursor past numbered lines for an unnumbered line after them" do
    write_lines(numbered(1, "First"), unnumbered("Unnumbered"))

    expect(feed.read(since: 1)[:cursor]).to eq(1)
  end

  it "reports zero unnumbered lines for a fully numbered log" do
    write_lines(numbered(1, "First"))

    expect(feed.read[:unnumbered]).to eq(0)
  end
end
