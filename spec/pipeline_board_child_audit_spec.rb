# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/child_audit"

# The board's defunct children, named by the command each ran while it was live, since `ps` shows
# a zombie's command as `<defunct>`.
RSpec.describe Hecks::Adapters::PipelineBoard::ChildAudit do
  let(:row) { described_class::Row }
  let(:table) { [] }
  let(:lines) { [] }
  let(:audit) do
    described_class.new(rows: -> { table }, parent: 10, log: ->(line) { lines << line }, now: -> { Time.utc(2026, 11, 15) })
  end

  def board(pid, stat, command) = row.new(pid, 10, stat, command)

  def settle(*tables)
    tables.each do |rows|
      table.replace(rows)
      audit.read
    end
  end

  it "names a child by the command it ran live, once it is defunct on two reads" do
    settle([board(20, "S", "gh pr list")], [board(20, "Z", "<defunct>")], [board(20, "Z", "<defunct>")])
    expect(lines).to eq(["board: defunct child pid=20 seen 2 reads running=gh pr list at=2026-11-15T00:00:00Z"])
  end

  it "says a child never seen live was not" do
    settle([board(20, "Z", "<defunct>")], [board(20, "Z", "<defunct>")])
    expect(lines.first).to include("running=never seen live")
  end

  it "does not report a child defunct on one read only", :aggregate_failures do
    settle([board(20, "Z", "<defunct>")], [])
    expect(lines).to be_empty
    expect(audit.read).to eq([])
  end

  it "reports a child once however long it stays" do
    settle(*Array.new(5) { [board(20, "Z", "<defunct>")] })
    expect(lines.size).to eq(1)
  end

  it "audits only the board's own children" do
    settle(*Array.new(3) { [row.new(30, 99, "Z", "<defunct>")] })
    expect(lines).to be_empty
  end

  it "answers the pids defunct now" do
    table.replace([board(20, "Z", "<defunct>"), board(21, "S", "tail")])
    expect(audit.read).to eq([20])
  end

  it "reads a real ps line" do
    expect(described_class.row("  7  1 Z+ <defunct>\n")).to eq(row.new(7, 1, "Z+", "<defunct>"))
  end

  it "reads the real process table, this process among its rows" do
    expect(described_class.table.map(&:pid)).to include(Process.pid)
  end
end
