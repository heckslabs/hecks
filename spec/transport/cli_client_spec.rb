require "spec_helper"
require "tmpdir"
require "hecks/transport/cli"
require_relative "../support/thread_parking"

# The Cli transport runs a program in its own process group, with its output in files, and stops
# the whole group when a run ends early.
RSpec.describe Hecks::Transport::Cli::Client, :process do
  # A child that ignores `TERM`: an ignored signal stays ignored across `exec`.
  TERM_PROOF = "(trap '' TERM; exec sleep 30)".freeze

  let(:client) { described_class.new }
  let(:cli) { Hecks::Transport::Cli }

  # Starts `sh -c` with a child of its own that writes its pid where the example can find it.
  def run_with_child(client, dir, then_do, child: "sleep 30")
    script = "#{child} & echo $! > #{dir}/child.pid; #{then_do}"
    client.run("sh", "-c", script, effect: :reads) { |reply| reply }
  end

  def child_pid(dir)
    Integer(File.read(File.join(dir, "child.pid")))
  end

  # Waits for a process that is not this one's child, so it cannot be reaped and waited on here.
  def gone?(pid)
    ThreadParking.wait_for(timeout: 2) { !alive?(pid) }
    true
  rescue ThreadParking::NeverReached
    false
  end

  # A stopped process can linger as a zombie until something reaps it, so a zombie counts as gone.
  def alive?(pid)
    Process.kill(0, pid)
    stat = "/proc/#{pid}/stat"
    !(File.exist?(stat) && File.read(stat).split[2] == "Z")
  rescue Errno::ESRCH
    false
  end

  # Runs the client in a thread, waits for the child to start, then interrupts the thread.
  def interrupt_while_waiting(dir)
    runner = Thread.new { run_with_child(described_class.new, dir, "wait") }
    runner.report_on_exception = false
    ThreadParking.wait_for { File.size?(File.join(dir, "child.pid")) }
    runner.raise(Interrupt)
    runner.join
  rescue Interrupt
    nil
  end

  it "hands the block the program's stdout, stderr and status", :aggregate_failures do
    reply = client.run("sh", "-c", "echo out; echo err >&2; exit 3", effect: :reads) { |r| [r.out, r.err, r.ok?] }

    expect(reply).to eq(["out\n", "err\n", false])
  end

  it "does not hand an argument to a shell to interpret" do
    expect(client.run("echo", "a; echo b", effect: :reads, &:out)).to eq("a; echo b\n")
  end

  it "removes the program's output when the block returns" do
    expect(File.exist?(client.run("echo", "x", effect: :reads, &:out_path))).to be(false)
  end

  it "keeps the output the block moves out of the run", :aggregate_failures do
    Dir.mktmpdir("cli") do |dir|
      kept = client.run("echo", "evidence", effect: :reads) { |reply| reply.keep(File.join(dir, "kept/out.json")) }
      expect(File.read(kept)).to eq("evidence\n")
    end
  end

  it "measures and fingerprints output without reading it" do
    expect(client.run("printf", "abc", effect: :reads) { |r| [r.bytes, r.sha256[0, 8]] }).to eq([3, "ba7816bf"])
  end

  it "answers a program that is not installed with NotInstalled" do
    expect { client.run("no-such-program-anywhere", effect: :reads) { nil } }.to raise_error(cli::NotInstalled, /no-such-program/)
  end

  it "stops a run that takes longer than its timeout" do
    timed = described_class.new(timeout: 0.2)
    expect { timed.run("sleep", "30", effect: :reads) { nil } }.to raise_error(cli::TimedOut, /within 0.2s/)
  end

  # The program exits on `TERM` but its child ignores it, so only the group `KILL` stops it.
  it "stops a child that ignores TERM after the program itself exits on TERM", :aggregate_failures do
    Dir.mktmpdir("cli") do |dir|
      run = -> { run_with_child(described_class.new(timeout: 0.3), dir, "trap 'exit 143' TERM; wait", child: TERM_PROOF) }
      expect(&run).to raise_error(cli::TimedOut)
      expect(gone?(child_pid(dir))).to be(true)
    end
  end

  it "stops the program and its children when the wait is interrupted" do
    Dir.mktmpdir("cli") do |dir|
      interrupt_while_waiting(dir)
      expect(gone?(child_pid(dir))).to be(true)
    end
  end

  it "refuses a run that is not a read when it is read-only, and runs nothing", :aggregate_failures do
    Dir.mktmpdir("cli") do |dir|
      run = -> { described_class.new(read_only: true).run("touch", "#{dir}/x", effect: :writes) { nil } }
      expect(&run).to raise_error(cli::ReadOnly, /read-only and the run writes/)
      expect(File.exist?("#{dir}/x")).to be(false)
    end
  end

  it "runs a read when it is read-only" do
    expect(described_class.new(read_only: true).run("echo", "ok", effect: :reads, &:out)).to eq("ok\n")
  end

  it "refuses an effect it does not know" do
    expect { client.run("true", effect: :deletes) { nil } }.to raise_error(ArgumentError, /not an effect/)
  end
end
