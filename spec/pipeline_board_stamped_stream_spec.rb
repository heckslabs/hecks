# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board's log lines carry the time: every line `warn`, `puts` and `print` write to the stamped
# standard error starts with it, and the stream put in place of `$stderr` is put back.
RSpec.describe Hecks::Adapters::PipelineBoard::StampedStream do
  let(:inner) { StringIO.new }
  let(:stream) { described_class.new(inner, clock: -> { Time.utc(2026, 11, 15, 21, 3, 4) }) }

  it "starts a line with the time" do
    stream.write("hello\n")
    expect(inner.string).to eq("2026-11-15T21:03:04Z hello\n")
  end

  it "stamps each line of a write that holds several" do
    stream.write("a\nb\n")
    expect(inner.string).to eq("2026-11-15T21:03:04Z a\n2026-11-15T21:03:04Z b\n")
  end

  it "does not stamp the middle of a line written in parts" do
    stream.print("a")
    stream.print("b\n")
    expect(inner.string).to eq("2026-11-15T21:03:04Z ab\n")
  end

  it "stamps what puts writes" do
    stream.puts("one", "two")
    expect(inner.string.lines.size).to eq(2)
  end

  it "answers the bytes of the text given" do
    expect(stream.write("abc")).to eq(3)
  end

  describe ".during" do
    def stamped_inside = described_class.during { $stderr.is_a?(described_class) }

    it "stamps $stderr inside the block and restores it after", :aggregate_failures do
      before = $stderr
      expect(stamped_inside).to be(true)
      expect($stderr).to equal(before)
    end

    def raising = described_class.during { raise "boom" }

    it "restores $stderr when the block raises", :aggregate_failures do
      before = $stderr
      expect { raising }.to raise_error("boom")
      expect($stderr).to equal(before)
    end

    it "does not stamp twice when entered inside itself" do
      described_class.during { described_class.during { expect($stderr.__getobj__).not_to be_a(described_class) } }
    end
  end
end
