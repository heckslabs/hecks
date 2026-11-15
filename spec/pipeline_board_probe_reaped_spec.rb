# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/pipeline_board/adapters/probe"

# Helpers that read the state of a process the example itself started, so another example's
# children never count.
module ProbeReapedHelpers
  # @return [String] the process's `ps` state, empty when it is gone, `Z` when defunct
  def state_of(pid) = Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s).first.strip

  # @return [Array<String>] a shell that writes its pid to the file and then sleeps
  def sleeper(pid_file) = ["sh", "-c", "echo $$ > #{pid_file}; sleep 30"]

  # Runs a reader of the probe and kills its thread after `passes` turns of the scheduler.
  # @return [Integer, nil] the pid the command wrote, when it got that far
  def killed_reader(pid_file, passes)
    reading = Thread.new { Hecks::Adapters::PipelineBoard::Probe.run(*sleeper(pid_file), seconds: 30) }
    (passes * 400).times { Thread.pass }
    reading.kill.join
    Integer(File.read(pid_file), exception: false) if File.exist?(pid_file)
  end
end

# A command a reader runs is waited on, past its bound and when its reading thread is killed.
RSpec.describe Hecks::Adapters::PipelineBoard::Probe do
  include ProbeReapedHelpers

  let(:dir) { Dir.mktmpdir("probe-reaped") }

  after { FileUtils.rm_rf(dir) }

  it "reaps a command that ran past its bound", :aggregate_failures do
    pid_file = File.join(dir, "pid")
    expect { described_class.run(*sleeper(pid_file), seconds: 0.3) }.to raise_error(StandardError)
    expect(state_of(Integer(File.read(pid_file)))).to eq("")
  end

  it "reaps the commands of readers killed at many moments" do
    pids = Array.new(12) { |index| killed_reader(File.join(dir, "pid#{index}"), index) }.compact
    expect(pids.reject { |pid| state_of(pid) == "" }).to eq([])
  end
end
