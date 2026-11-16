# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/child_audit"

# The board's defunct children, named by the command each ran while it was live, since `ps` shows
# a zombie's command as `<defunct>`.
RSpec.describe Hecks::Adapters::PipelineBoard::ChildAudit do
  let(:row) { described_class::Row }
  let(:table) { [] }
  let(:lines) { [] }
  let(:reaped) { [] }
  let(:audit) do
    described_class.new(rows: -> { table }, parent: 10, log: ->(line) { lines << line }, now: -> { Time.utc(2026, 11, 15) },
                        reap: ->(pid) { reaped << pid })
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

  it "does not reap a child on its first defunct read" do
    settle([board(20, "Z", "<defunct>")])
    expect(reaped).to be_empty
  end

  it "reaps a child defunct on two reads" do
    settle([board(20, "Z", "<defunct>")], [board(20, "Z", "<defunct>")])
    expect(reaped).to eq([20])
  end

  it "reaps only the board's own children" do
    settle(*Array.new(3) { [row.new(30, 99, "Z", "<defunct>")] })
    expect(reaped).to be_empty
  end

  def ordered_audit(order)
    described_class.new(rows: -> { table }, parent: 10, log: ->(_line) { order << :log }, reap: ->(_pid) { order << :reap })
  end

  it "logs a child before it reaps it" do
    order = []
    audited = ordered_audit(order)
    table.replace([board(20, "Z", "<defunct>")])
    2.times { audited.read }
    expect(order).to eq(%i[log reap])
  end

  # Spawns a child, waits for it to exit without waiting on its pid, and answers the pid.
  def exited_child
    out, writer = IO.pipe
    pid = Process.spawn("true", out: writer)
    writer.close
    out.read
    pid
  end

  def reap_when_exited(pid) = described_class.reap(pid) || reap_when_exited(pid)

  it "reaps a real child that no one waits on, and a late waiter finds it gone", :aggregate_failures do
    pid = exited_child
    expect(Timeout.timeout(5) { reap_when_exited(pid) }).to eq(pid)
    expect { Process.wait(pid) }.to raise_error(Errno::ECHILD)
  end

  it "answers nil for a child already gone" do
    expect(described_class.reap(Process.pid + 1_000_000)).to be_nil
  end

  it "reads the real process table, this process among its rows" do
    expect(described_class.table.map(&:pid)).to include(Process.pid)
  end
end
