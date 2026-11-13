# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_journal/tail"

# The board's follower of one log file: a read takes the bytes written since the last one and no
# more, whatever the file's size, and a file that is not the one read before is read anew.
RSpec.describe Hecks::Adapters::PipelineBoard::Tail do
  let(:dir) { Dir.mktmpdir("tail") }
  let(:log) { File.join(dir, "events.jsonl") }
  let(:tail) { described_class.new }

  after { FileUtils.rm_rf(dir) }

  def append(text) = File.write(log, text, mode: "a")

  # A line of exactly `size` bytes, its newline included.
  def line(tag, size = 100) = "#{tag.ljust(size - 1, ".")}\n"

  def lines_of(reader = tail) = reader.advance(log).lines

  it "reads a new file from its start", :aggregate_failures do
    append(line("a") + line("b"))
    read = tail.advance(log)
    expect(read.anew).to be(true)
    expect(read.lines).to eq([line("a"), line("b")])
  end

  it "reads only the bytes appended since the last read", :aggregate_failures do
    append(line("a") * 50)
    lines_of
    append(line("b"))
    expect(lines_of).to eq([line("b")])
    expect(tail.bytes_read).to eq(5100)
  end

  it "reads nothing, and no byte, while the file stands as it was", :aggregate_failures do
    append(line("a"))
    lines_of
    expect(lines_of).to eq([])
    expect(tail.bytes_read).to eq(100)
  end

  it "leaves a line that is still being written until its end arrives", :aggregate_failures do
    append("#{line("a")}half")
    expect(lines_of).to eq([line("a")])
    append(" done\n")
    expect(lines_of).to eq(["half done\n"])
  end

  it "reads a shortened file anew" do
    append(line("a") + line("b"))
    lines_of
    File.write(log, line("c"))
    expect(tail.advance(log).to_a).to eq([true, [line("c")]])
  end

  it "reads a file put in the place of the one it followed anew, though it is the same size" do
    append(line("a"))
    lines_of
    File.write("#{log}.new", line("b"))
    File.rename("#{log}.new", log)
    expect(tail.advance(log).to_a).to eq([true, [line("b")]])
  end

  it "reads a file rewritten in place to the same size anew" do
    append(line("a"))
    lines_of
    File.write(log, line("b"))
    expect(tail.advance(log).to_a).to eq([true, [line("b")]])
  end

  it "follows a file shorter than the bytes that identify it as it grows", :aggregate_failures do
    append("a\n")
    lines_of
    append("b\n")
    expect(tail.advance(log).to_a).to eq([false, ["b\n"]])
    expect(tail.advance(log.tap { append(line("c")) }).to_a).to eq([false, [line("c")]])
  end

  it "follows a file to the name a rotation gave it" do
    append(line("a"))
    lines_of
    append(line("b"))
    File.rename(log, "#{log}.1")
    expect(tail.advance("#{log}.1").to_a).to eq([false, [line("b")]])
  end

  it "holds no lines for a file that is not there" do
    expect(tail.advance(log).to_a).to eq([true, []])
  end

  describe "holding the newest lines" do
    let(:newest) { described_class.new(last: 3) }

    it "takes the last lines of a long file without reading it whole", :aggregate_failures do
      append(line("old", 1000) * 2000)
      append(line("x") + line("y") + line("z"))
      expect(lines_of(newest)).to eq([line("x"), line("y"), line("z")])
      expect(newest.bytes_read).to be <= 2 * described_class::BLOCK
    end

    it "takes every line of a file that holds fewer" do
      append(line("x") + line("y"))
      expect(lines_of(newest)).to eq([line("x"), line("y")])
    end

    it "then reads what is appended, as any follower does" do
      append(line("x") * 10)
      lines_of(newest)
      append(line("y"))
      expect(newest.advance(log).to_a).to eq([false, [line("y")]])
    end
  end
end
