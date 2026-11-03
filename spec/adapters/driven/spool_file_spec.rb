require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hecks/catcher/adapters/spool_file"

# The `Spool` port's adapter, against spool files a spec writes in a scratch directory.
RSpec.describe Hecks::Adapters::SpoolFile do
  let(:scratch) { Dir.mktmpdir("spool-file") }
  let(:path) { File.join(scratch, "observations.spool") }
  let(:sidecar) { "#{path}.cursor" }
  let(:adapter) { described_class.new(settings: { path: path }) }

  def entry(id, **over)
    { observation_id: id, source: "claude_code", tool: "Bash", subject: "ls", succeeded: true,
      observed_in: "/work", observed_at: "2026-11-02T10:00:00Z" }.merge(over)
  end

  def spool(*lines) = File.write(path, lines.map { |line| "#{line}\n" }.join)

  def json(id, **over) = JSON.generate(entry(id, **over))

  def ids(answer) = answer[:lines].map { |row| row[:call_id] }

  def fingerprint = [File.read(path), File.mtime(path), File.stat(path).ino]

  after { FileUtils.rm_rf(scratch) }

  describe "#read" do
    it "answers each line as a call, with the line's observation_id as call_id" do
      spool(json("a"), json("b", succeeded: false))

      answer = adapter.read(run: { value: "r1" })

      expect(answer[:lines]).to eq([
        { call_id: "a", source: "claude_code", tool: "Bash", subject: "ls", succeeded: true,
          observed_in: "/work", observed_at: "2026-11-02T10:00:00Z" },
        { call_id: "b", source: "claude_code", tool: "Bash", subject: "ls", succeeded: false,
          observed_in: "/work", observed_at: "2026-11-02T10:00:00Z" }
      ])
      expect(answer[:through]).to eq(value: 2)
    end

    it "answers only the lines after the acknowledged cursor" do
      spool(json("a"), json("b"), json("c"))
      adapter.acknowledge(run: "r1", through: { value: 2 })

      answer = adapter.read(run: "r1")

      expect(ids(answer)).to eq(%w[c])
      expect(answer[:through]).to eq(value: 3)
    end

    it "counts blank and invalid lines in through but does not answer them" do
      spool(json("a"), "", "   ", "{not json", "[1]", '{"tool":"Bash"}', json("b"))

      answer = adapter.read(run: "r1")

      expect(ids(answer)).to eq(%w[a b])
      expect(answer[:through]).to eq(value: 7)
    end

    it "leaves a final line the hook has not finished" do
      File.write(path, "#{json("a")}\n#{json("b")[0, 20]}")

      answer = adapter.read(run: "r1")

      expect(ids(answer)).to eq(%w[a])
      expect(answer[:through]).to eq(value: 1)
    end

    it "answers no lines and the current cursor when the spool is missing" do
      File.write(sidecar, "4\n")

      expect(adapter.read(run: "r1")).to eq(lines: [], through: { value: 4 })
      expect(File.exist?(path)).to be(false)
    end

    it "answers through 0 when nothing is spooled or acknowledged" do
      expect(adapter.read(run: "r1")).to eq(lines: [], through: { value: 0 })
    end

    it "does not modify the spool" do
      spool(json("a"), "", "broken")
      before = fingerprint

      adapter.read(run: "r1")

      expect(fingerprint).to eq(before)
    end
  end

  describe "#acknowledge" do
    it "moves the cursor forward and answers nothing" do
      expect(adapter.acknowledge(run: "r1", through: { value: 3 })).to eq({})
      expect(File.read(sidecar).to_i).to eq(3)

      adapter.acknowledge(run: "r1", through: 5)

      expect(File.read(sidecar).to_i).to eq(5)
    end

    it "never moves the cursor backward" do
      adapter.acknowledge(run: "r1", through: 5)
      adapter.acknowledge(run: "r1", through: 2)

      expect(File.read(sidecar).to_i).to eq(5)
    end

    it "writes the sidecar by renaming a temporary file, leaving none behind" do
      allow(File).to receive(:rename).and_call_original

      adapter.acknowledge(run: "r1", through: 1)

      expect(File).to have_received(:rename).with(%r{observations\.spool\.cursor\..*\.tmp\z}, sidecar)
      expect(Dir.children(scratch)).to eq(["observations.spool.cursor"])
    end

    it "does not modify the spool" do
      spool(json("a"), json("b"))
      before = fingerprint

      adapter.acknowledge(run: "r1", through: 2)

      expect(fingerprint).to eq(before)
    end
  end

  it "defaults the path to the hook's spool under the home directory" do
    expect(described_class.new.instance_variable_get(:@path))
      .to eq(File.expand_path("~/.claude/hecks-dev/observations.spool"))
  end
end
