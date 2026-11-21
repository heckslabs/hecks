# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/roundhouse/adapters/metering"

# Roundhouse's per-session meter (ADR 0222, phase 2): each live Claude session's role, Work item,
# memory (its whole process tree, its MCP servers counted), CPU and last activity, read from
# `claude agents --json` and `ps`. Every outside read is a stand-in here.
RSpec.describe Hecks::Adapters::Metering do
  let(:now) { Time.utc(2026, 11, 19, 18, 0, 0) }

  # pid, ppid, resident memory in kilobytes, %cpu, command
  let(:ps) do
    <<~PS
      100     1  512000  12.5 claude --agent coder
      101   100  204800   3.0 ruby -I lib -e require 'hecks/adapters/driving/mcp/stdio_entry'; Hecks::Adapters::Driving::Mcp.serve_stdio(ARGV) --
      102   100  102400   1.5 ruby -I lib -e require 'hecks/query_ir_mcp/stdio_entry'; Hecks::QueryIrMcp.serve_stdio(ARGV) --
      103   101   10240   0.5 git status
      200     1  307200   0.5 claude
      300     1  409600   2.0 claude
      400     1 1048576  40.0 /Applications/Safari.app/Contents/MacOS/Safari
    PS
  end

  let(:listing) do
    started = (now.to_i - 3600) * 1000
    [
      { "id" => "aaaa1111", "sessionId" => "aaaa1111-full", "pid" => 100, "name" => "signalbox-phase-2-shadow",
        "kind" => "background", "state" => "working", "status" => "busy", "startedAt" => started,
        "cwd" => "/repo/.claude/worktrees/signalbox-phase-2-shadow" },
      { "id" => "bbbb2222", "sessionId" => "bbbb2222-full", "pid" => 200, "name" => "orchestrator-seat-2",
        "kind" => "background", "state" => "working", "status" => "idle", "startedAt" => started, "cwd" => "/repo" },
      { "sessionId" => "cccc3333-full", "pid" => 300, "name" => "miette2-c3", "kind" => "interactive",
        "status" => "idle", "startedAt" => started, "cwd" => "/elsewhere" },
      { "id" => "dddd4444", "sessionId" => "dddd4444-full", "name" => "finished-long-ago", "kind" => "background",
        "state" => "done", "startedAt" => started, "cwd" => "/repo" }
    ]
  end

  let(:metering) do
    run = { run: "signalbox-phase-2-shadow", agent: "", works_as: "coder", work: "signalbox-phase-2-shadow" }
    runs = { "aaaa1111-full" => run }
    machine_reads = {
      memsize: 38_654_705_664, cores: 6, loadavg: "{ 33.97 35.28 28.52 }",
      vm_stat: "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages active:   759487.\n" \
               "Pages wired down:   320011.\nPages occupied by compressor:   230127.\n"
    }
    described_class.new(settings: { listing: -> { listing }, processes: -> { ps }, runs: -> { runs },
                                    machine: -> { machine_reads }, now: -> { now },
                                    activity: ->(entry) { entry["sessionId"] == "aaaa1111-full" ? now - 120 : nil } })
  end

  let(:rows) { metering.rows.to_h { |row| [row[:session], row] } }

  it "meters only the live sessions: a listed session with no process draws nothing" do
    expect(rows.keys).to contain_exactly("aaaa1111-full", "bbbb2222-full", "cccc3333-full")
  end

  it "counts a session's whole process tree, its MCP servers and their children", :aggregate_failures do
    coder = rows.fetch("aaaa1111-full")

    expect(coder[:memory_mb]).to eq(810)
    expect(coder[:cpu]).to eq(17.5)
    expect(coder[:mcp_servers]).to eq(2)
    expect(coder[:processes]).to eq(4)
  end

  it "names a dispatched session's role and Work item from its run", :aggregate_failures do
    coder = rows.fetch("aaaa1111-full")

    expect(coder[:role]).to eq("coder")
    expect(coder[:works_as]).to eq("coder")
    expect(coder[:item]).to eq("signalbox-phase-2-shadow")
  end

  it "takes an unrun session's role from its name, and a person's own session as the person's" do
    expect(rows.transform_values { |row| row[:role] }).to eq(
      "aaaa1111-full" => "coder", "bbbb2222-full" => "orchestrator", "cccc3333-full" => "person"
    )
  end

  it "says when a session last did something and how long it has stood", :aggregate_failures do
    coder = rows.fetch("aaaa1111-full")

    expect(coder[:last_activity]).to eq("2026-11-19T17:58:00Z")
    expect(coder[:idle_minutes]).to eq(2)
    expect(coder[:age_minutes]).to eq(60)
    expect(rows.fetch("bbbb2222-full")[:idle_minutes]).to eq(60)
  end

  it "answers the Sessions query as a JSON document" do
    sessions = JSON.parse(metering.sessions.fetch(:text))

    expect(sessions.map { |row| row["session"] }).to include("aaaa1111-full")
  end

  it "reads the machine: capacity, everything used, the sessions' draw, the load and the performance cores" do
    expect(metering.machine_facts).to include(capacity_mb: 36_864, used_mb: 20_463, drawn_mb: 1110,
                                              person_mb: 400, load: 3397, cores: 6, sessions: 3)
  end

  it "meters a coder's draw as the median of the live coders' memory" do
    expect(metering.machine_facts).to include(coder_draw_mb: 810)
  end

  it "passes on the kernel's memory pressure level as the number it reads" do
    machine_reads = { memsize: 1, cores: 6, loadavg: "{ 1.0 }", vm_stat: "", memory_pressure_level: "1\n" }
    gauge = Hecks::Adapters::Metering::MachineGauge.new(machine_reads)

    expect(gauge.memory_pressure_level).to eq(1)
  end

  it "reads the load against every core the machine has, the efficiency cores with the performance ones" do
    reads = { memsize: 1, cores: 12, perf_cores: 6, loadavg: "{ 9.00 9.00 9.00 }", vm_stat: "" }

    expect(Hecks::Adapters::Metering::MachineGauge.new(reads).cores).to eq(12)
  end

  it "reads no memory pressure level as 0, unread" do
    expect(metering.machine_facts).to include(memory_pressure_level: 0)
  end

  it "answers the Machine query as a JSON document" do
    expect(JSON.parse(metering.machine.fetch(:text))).to include("capacity_mb" => 36_864)
  end

  it "reads the machine's load alone without listing a session or reading the process table" do
    reads = { memsize: 1, cores: 6, loadavg: "{ 7.02 15.23 20.46 }", vm_stat: "" }
    alone = described_class.new(settings: { listing: -> { raise "listed" }, processes: -> { raise "ps" },
                                            machine: -> { reads }, now: -> { now } })

    expect(alone.load_facts).to eq(load: 702, cores: 6, taken_at: "2026-11-19T18:00:00Z")
  end

  it "answers no load when the load could not be read, never a calm 0" do
    blank = described_class.new(settings: { machine: -> { { loadavg: "" } }, now: -> { now } })

    expect(blank.load_facts[:load]).to be_nil
  end
end
