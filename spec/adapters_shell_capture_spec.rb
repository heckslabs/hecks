# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/shell"

RSpec.describe Hecks::Adapters::Shell do
  subject(:shell) { described_class.new }

  # A duration no other process sleeps for, so the child is named by its own arguments.
  let(:seconds) { "31.#{Process.pid}" }

  def child_pid = IO.popen(["pgrep", "-f", "sleep #{seconds}"], &:read).split.first&.to_i

  # Starts a capture of a blocking child, waits until the child runs, then kills the caller.
  def killed_mid_read
    caller_thread = Thread.new { shell.capture("sleep", seconds) }
    Thread.pass until child_pid
    caller_thread.kill.join
  end

  it "answers a program's output and status", :aggregate_failures do
    result = shell.capture("sh", "-c", "echo out; echo err >&2; exit 3")
    expect([result.out, result.err, result.exit_code]).to eq(["out\n", "err\n", 3])
  end

  it "answers 127 with the reason for a program that is not installed", :aggregate_failures do
    result = shell.capture("hecks-no-such-program")
    expect([result.ok?, result.exit_code]).to eq([false, 127])
  end

  it "leaves no reader thread dead on a closed stream when the caller is killed" do
    before = Thread.list
    killed_mid_read
    expect((Thread.list - before).select { |thread| thread.status.nil? }).to be_empty
  end

  it "stops the program when the caller is killed" do
    killed_mid_read
    expect(child_pid).to be_nil
  end
end
