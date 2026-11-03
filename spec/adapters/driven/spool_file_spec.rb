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
  let(:answer) { Hecks::Adapters::SpoolFile.new(settings: { path: path }).read(run: { value: "r1" }) }

  def sidecar = "#{path}.cursor"

  def cursor = Hecks::Adapters::SpoolCursorFile.new(settings: { path: path })

  def entry(id, **over)
    { observation_id: id, source: "claude_code", tool: "Bash", subject: "ls", succeeded: true,
      observed_in: "/work", observed_at: "2026-11-02T10:00:00Z" }.merge(over)
  end

  def call(id, **over)
    entry(id, **over).except(:observation_id).merge(call_id: id)
  end

  def spool(*lines) = File.write(path, lines.map { |line| "#{line}\n" }.join)

  def json(id, **over) = JSON.generate(entry(id, **over))

  def ids = answer[:lines].map { |row| row[:call_id] }

  def through = answer[:through]

  def held_cursor = File.read(sidecar).to_i

  def fingerprint = [File.read(path), File.mtime(path), File.stat(path).ino]

  def acknowledge(count) = cursor.acknowledge(sitting: "s1", through: count)

  after { FileUtils.rm_rf(scratch) }

  describe Hecks::Adapters::SpoolFile do
    it "answers each line as a call, with the line's observation_id as call_id" do
      spool(json("a"), json("b", succeeded: false))

      expect(answer[:lines]).to eq([call("a"), call("b", succeeded: false)])
    end

    it "counts the lines it read in through" do
      spool(json("a"), json("b"))

      expect(through).to eq(value: 2)
    end

    context "with a cursor after two of three lines" do
      before do
        spool(json("a"), json("b"), json("c"))
        acknowledge(value: 2)
      end

      it("answers only the lines after it") { expect(ids).to eq(%w[c]) }

      it("answers the whole count in through") { expect(through).to eq(value: 3) }
    end

    context "with blank and invalid lines" do
      before { spool(json("a"), "", "   ", "{not json", "[1]", '{"tool":"Bash"}', json("b")) }

      it("does not answer them") { expect(ids).to eq(%w[a b]) }

      it("counts them in through") { expect(through).to eq(value: 7) }
    end

    context "with a final line the hook has not finished" do
      before { File.write(path, "#{json("a")}\n#{json("b")[0, 20]}") }

      it("leaves it unanswered") { expect(ids).to eq(%w[a]) }

      it("leaves it uncounted") { expect(through).to eq(value: 1) }
    end

    context "with no spool" do
      before { File.write(sidecar, "4\n") }

      it("answers no lines") { expect(answer[:lines]).to eq([]) }

      it("answers the current cursor in through") { expect(through).to eq(value: 4) }

      it "does not create the spool" do
        answer

        expect(File.exist?(path)).to be(false)
      end
    end

    it "answers through 0 when nothing is spooled or acknowledged" do
      expect(through).to eq(value: 0)
    end

    it "does not modify the spool" do
      spool(json("a"), "", "broken")
      before = fingerprint
      answer

      expect(fingerprint).to eq(before)
    end

    it "does not write a cursor" do
      spool(json("a"))
      answer

      expect(File.exist?(sidecar)).to be(false)
    end

    it "defaults the path to the hook's spool under the home directory" do
      expect(Hecks::Adapters::SpoolCursor.new.spool)
        .to eq(File.expand_path("~/.claude/hecks-dev/observations.spool"))
    end
  end

  describe Hecks::Adapters::SpoolCursorFile do
    it "answers nothing to an acknowledge" do
      expect(acknowledge({ value: 3 })).to eq({})
    end

    it "moves the cursor forward" do
      acknowledge({ value: 3 })
      acknowledge(5)

      expect(held_cursor).to eq(5)
    end

    it "ignores the rest of the sitting" do
      cursor.acknowledge(sitting: { value: "s1" }, through: { value: 2 }, calls: [{ call_id: "a" }])

      expect(held_cursor).to eq(2)
    end

    it "never moves the cursor backward" do
      acknowledge(5)
      acknowledge(2)

      expect(held_cursor).to eq(5)
    end

    it "writes the sidecar by renaming a temporary file" do
      allow(File).to receive(:rename).and_call_original
      acknowledge(1)

      expect(File).to have_received(:rename).with(/observations\.spool\.cursor\..*\.tmp\z/, sidecar)
    end

    it "leaves no temporary file behind" do
      acknowledge(1)

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
