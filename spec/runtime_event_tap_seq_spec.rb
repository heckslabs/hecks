# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/runtime/event_tap"
require "hecks/runtime/event_log"

# The sequence number on each tap line follows the last one written, across writers that share
# the log, rotations and restarts. Two taps on one path must never restart the sequence.
RSpec.describe Hecks::Runtime::EventTap, "sequence numbers" do
  let(:dir) { Dir.mktmpdir("tap-seq") }
  let(:path) { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def event(name, n)
    Hecks::Runtime::Event.new(name: name, aggregate: "Hecks::Thing", id: "id-#{n}", payload: {},
                              occurred_at: "2026-11-04T10:00:00Z")
  end

  def sequence_numbers
    File.readlines(path, chomp: true).map { |line| JSON.parse(line)["seq"] }
  end

  it "keeps numbering when a second tap on the same path takes over the log" do
    first = described_class.new(path: path)
    second = described_class.new(path: path)

    3.times { |n| first.event(event("First", n)) }
    3.times { |n| second.event(event("Second", n)) }
    2.times { |n| first.event(event("First", n + 3)) }

    expect(sequence_numbers).to eq((1..8).to_a)
  end

  it "keeps numbering across a restart of the tap" do
    described_class.new(path: path).event(event("Before", 0))
    described_class.new(path: path).event(event("After", 0))

    expect(sequence_numbers).to eq([1, 2])
  end

  it "keeps numbering across a rotation" do
    tap = described_class.new(path: path, max_bytes: 200)
    12.times { |n| tap.event(event("Rotating", n)) }

    numbers = (0..described_class::KEPT).flat_map do |generation|
      file = generation.zero? ? path : "#{path}.#{generation}"
      next [] unless File.file?(file)

      File.readlines(file, chomp: true).map { |line| JSON.parse(line)["seq"] }
    end

    expect(numbers.sort).to eq((1..12).to_a)
  end
end
