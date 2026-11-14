# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/pipeline_journal/tap"

# The board's reader of the event log reads what the log gained, not the log: the tail by byte
# offset, a rotated generation once, and nothing while the log stands as it was read. The log here
# is a scratch one under a temporary directory.
RSpec.describe Hecks::Adapters::PipelineBoard::Tap do
  let(:dir) { Dir.mktmpdir("tap-bounded") }
  let(:log) { File.join(dir, "events.jsonl") }
  let(:tap) { described_class.new(log, names: -> { %w[Landed Pushed] }) }

  after { FileUtils.rm_rf(dir) }

  def line(name, id = "r1") = "#{JSON.generate(kind: "event", at: "2026-11-02T10:00:00Z", aggregate: "A", id: id, event: name)}\n"

  def append(*lines) = File.write(log, lines.join, mode: "a")

  # Moves the live log to the first rotated generation, as the runtime's tap does.
  def rotate
    4.downto(1) { |n| File.rename("#{log}.#{n}", "#{log}.#{n + 1}") if File.file?("#{log}.#{n}") }
    File.rename(log, "#{log}.1")
  end

  def names(rows) = rows.map { |row| row[:name] }

  describe "the newest rows" do
    it "holds what a fresh reader of the same log holds, after appends", :aggregate_failures do
      append(line("Landed"))
      tap.rows
      append("not json\n", line("Pushed"))
      expect(tap.rows).to eq(described_class.new(log).rows)
      expect(names(tap.rows)).to eq(%w[Landed Pushed])
    end

    it "reads only the appended bytes on the next call" do
      append(line("Landed") * 200)
      tap.rows
      append(line("Pushed"))
      expect { tap.rows }.to change(tap, :bytes_read).by(line("Pushed").bytesize)
    end

    it "reads no byte and links nothing again while the log stands", :aggregate_failures do
      append(line("Landed"))
      first = tap.rows
      expect { tap.rows }.not_to change(tap, :bytes_read)
      expect(tap.rows).to equal(first)
    end

    it "keeps no more than the tail's lines" do
      append(line("Landed") * (described_class::TAIL_LINES + 50))
      tap.rows
      append(line("Pushed"))
      expect(tap.rows.size).to eq(described_class::TAIL_LINES)
    end

    it "holds only the new live log after a rotation, as a fresh reader does", :aggregate_failures do
      append(line("Landed"))
      tap.rows
      rotate
      append(line("Pushed"))
      expect(names(tap.rows)).to eq(%w[Pushed])
    end

    it "holds nothing for a log that is not there" do
      expect(tap.rows).to eq([])
    end
  end

  describe "the events of a name, from the whole log" do
    before do
      append(line("Landed", "old"), line("Other"))
      rotate
      append(line("Pushed"), line("Landed", "new"))
    end

    it "reads every generation, oldest first" do
      expect(tap.named(%w[Landed]).map { |row| row[:id] }).to eq(%w[old new])
    end

    it "reads a rotated generation once, whatever names are asked after" do
      tap.named(%w[Landed])
      expect { tap.named(%w[Pushed]) }.not_to change(tap, :bytes_read)
    end

    it "reads only what the live log gained", :aggregate_failures do
      tap.named(%w[Landed])
      append(line("Landed", "newer"))
      expect { tap.named(%w[Landed]) }.to change(tap, :bytes_read).by(line("Landed", "newer").bytesize)
      expect(tap.named(%w[Landed]).map { |row| row[:id] }).to eq(%w[old new newer])
    end

    it "follows a generation to its next name without reading it again", :aggregate_failures do
      tap.named(%w[Landed])
      rotate
      expect { tap.named(%w[Landed]) }.not_to change(tap, :bytes_read)
      expect(tap.named(%w[Landed]).map { |row| row[:id] }).to eq(%w[old new])
    end

    it "forgets a generation the log dropped" do
      tap.named(%w[Landed])
      File.delete("#{log}.1")
      expect(tap.named(%w[Landed]).map { |row| row[:id] }).to eq(%w[new])
    end

    it "answers a name outside its index by reading the log again" do
      tap.named(%w[Landed])
      expect(names(tap.named(%w[Other]))).to eq(%w[Other])
    end

    it "keeps the answer while no file grew" do
      expect(tap.named(%w[Landed])).to equal(tap.named(%w[Landed]))
    end
  end
end
