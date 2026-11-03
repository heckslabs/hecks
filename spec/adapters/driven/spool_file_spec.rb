require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hecks/catcher/adapters/spool_file"
require "hecks/catcher/adapters/spool_cursor_file"

# The `Spool` and `SpoolCursor` ports' adapters, against spool files a spec writes in a scratch
# directory.
RSpec.describe "the catcher's spool adapters" do
  let(:scratch) { Dir.mktmpdir("spool-file") }
  let(:path) { File.join(scratch, "observations.spool") }
  let(:sidecar) { "#{path}.cursor" }
  let(:reader) { Hecks::Adapters::SpoolFile.new(settings: { path: path }) }
  let(:cursor) { Hecks::Adapters::SpoolCursorFile.new(settings: { path: path }) }

  def entry(id, **over)
    { observation_id: id, source: "claude_code", tool: "Bash", subject: "ls", succeeded: true,
      observed_in: "/work", observed_at: "2026-11-02T10:00:00Z" }.merge(over)
  end

  def spool(*lines) = File.write(path, lines.map { |line| "#{line}\n" }.join)

  def json(id, **over) = JSON.generate(entry(id, **over))

  def ids(answer) = answer[:lines].map { |row| row[:call_id] }

  def fingerprint = [File.read(path), File.mtime(path), File.stat(path).ino]

  def acknowledge(through) = cursor.acknowledge(sitting: "s1", through: through)

  after { FileUtils.rm_rf(scratch) }

  describe Hecks::Adapters::SpoolFile do
    describe "#read" do
      it "answers each line as a call, with the line's observation_id as call_id" do
        spool(json("a"), json("b", succeeded: false))

        answer = reader.read(run: { value: "r1" })

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
        acknowledge(value: 2)

        answer = reader.read(run: "r1")

        expect(ids(answer)).to eq(%w[c])
        expect(answer[:through]).to eq(value: 3)
      end

      it "counts blank and invalid lines in through but does not answer them" do
        spool(json("a"), "", "   ", "{not json", "[1]", '{"tool":"Bash"}', json("b"))

        answer = reader.read(run: "r1")

        expect(ids(answer)).to eq(%w[a b])
        expect(answer[:through]).to eq(value: 7)
      end

      it "leaves a final line the hook has not finished" do
        File.write(path, "#{json("a")}\n#{json("b")[0, 20]}")

        answer = reader.read(run: "r1")

        expect(ids(answer)).to eq(%w[a])
        expect(answer[:through]).to eq(value: 1)
      end

      it "answers no lines and the current cursor when the spool is missing" do
        File.write(sidecar, "4\n")

        expect(reader.read(run: "r1")).to eq(lines: [], through: { value: 4 })
        expect(File.exist?(path)).to be(false)
      end

      it "answers through 0 when nothing is spooled or acknowledged" do
        expect(reader.read(run: "r1")).to eq(lines: [], through: { value: 0 })
      end

      it "does not modify the spool or write a cursor" do
        spool(json("a"), "", "broken")
        before = fingerprint

        reader.read(run: "r1")

        expect(fingerprint).to eq(before)
        expect(File.exist?(sidecar)).to be(false)
      end

      it "defaults the path to the hook's spool under the home directory" do
        expect(Hecks::Adapters::SpoolCursor.new.spool)
          .to eq(File.expand_path("~/.claude/hecks-dev/observations.spool"))
      end
    end
  end

  describe Hecks::Adapters::SpoolCursorFile do
    describe "#acknowledge" do
      it "moves the cursor forward and answers nothing" do
        expect(acknowledge({ value: 3 })).to eq({})
        expect(File.read(sidecar).to_i).to eq(3)

        acknowledge(5)

        expect(File.read(sidecar).to_i).to eq(5)
      end

      it "ignores the rest of the sitting" do
        cursor.acknowledge(sitting: { value: "s1" }, through: { value: 2 }, calls: [{ call_id: "a" }])

        expect(File.read(sidecar).to_i).to eq(2)
      end

      it "never moves the cursor backward" do
        acknowledge(5)
        acknowledge(2)

        expect(File.read(sidecar).to_i).to eq(5)
      end

      it "writes the sidecar by renaming a temporary file, leaving none behind" do
        allow(File).to receive(:rename).and_call_original

        acknowledge(1)

        expect(File).to have_received(:rename).with(%r{observations\.spool\.cursor\..*\.tmp\z}, sidecar)
        expect(Dir.children(scratch)).to eq(["observations.spool.cursor"])
      end

      it "does not modify the spool" do
        spool(json("a"), json("b"))
        before = fingerprint

        acknowledge(2)

        expect(fingerprint).to eq(before)
      end
    end
  end
end
