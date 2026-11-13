# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/pipeline_board/adapters/probe"

# A slow command whose shell starts a background sleep (a grandchild that holds the output pipe),
# hands its pid through a FIFO and waits on it.
module ProbeChildCommands
  def slow_command
    File.mkfifo(pid_file) unless File.exist?(pid_file)
    ["sh", "-c", "sleep 30 & echo $! > #{pid_file}; wait"]
  end

  # Blocks until the shell writes the pid.
  def written_pid = Integer(File.read(pid_file))

  # Whether the process has exited: gone, or a zombie waiting to be reaped by init. The probe
  # returns only once the output pipe the grandchild held is closed, so it has exited by then.
  def gone?(pid)
    stat, = Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s)
    stat.strip.empty? || stat.strip.start_with?("Z")
  end
end

# A command the board runs never outlives its read: past its bound, or when the reading thread is
# killed, its whole process group is stopped and reaped, so a slow read on a loaded machine adds no
# process that runs on.
RSpec.describe Hecks::Adapters::PipelineBoard::Probe do
  include ProbeChildCommands

  let(:dir) { Dir.mktmpdir("probe-child") }
  let(:pid_file) { File.join(dir, "pid") }
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }

  after { FileUtils.rm_rf(dir) }

  it "answers the command's output" do
    expect(described_class.run("sh", "-c", "cat; echo done", stdin: "in ")).to eq("in done\n")
  end

  it "gives a command past its bound as unavailable" do
    expect { described_class.run(*slow_command, seconds: 0.3) }.to raise_error(unavailable, /did not answer in 0.3s/)
  end

  it "stops the command and its children when it runs past its bound", :aggregate_failures do
    command = slow_command
    pid = Thread.new { written_pid }
    expect { described_class.run(*command, seconds: 0.5) }.to raise_error(unavailable)
    expect(gone?(pid.value)).to be(true)
  end

  it "stops the command when the thread reading it is killed" do
    command = slow_command
    reading = Thread.new { described_class.run(*command, seconds: 30) }
    pid = written_pid
    reading.kill.join
    expect(gone?(pid)).to be(true)
  end

  it "gives a command that exits non-zero as unavailable, with its reason" do
    expect { described_class.run("sh", "-c", "echo nope >&2; exit 3") }.to raise_error(unavailable, /nope/)
  end
end
