# frozen_string_literal: true

require "spec_helper"

# The real tool: `taskpolicy -b` replaces itself with its command, so the process group a bounded
# run leads is the command's own and the bound's kill reaches it.
RSpec.describe "Batch priority under the real taskpolicy", if: RUBY_PLATFORM.include?("darwin") do
  let(:tool) { "/usr/sbin/taskpolicy" }

  def start
    reader, writer = IO.pipe
    pid = Process.spawn(tool, "-b", "sh", "-c", "echo ready; exec sleep 30", pgroup: true, out: writer)
    writer.close
    reader.gets
    pid
  end

  def end_group(pid)
    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  it "leaves the command itself as the process the group leader started" do
    pid = start
    expect(IO.popen(["ps", "-o", "comm=", "-p", pid.to_s], &:read).strip).to end_with("sleep")
  ensure
    end_group(pid) if pid
  end

  it "ends with the group when the bound kills it" do
    pid = start
    Process.kill("TERM", -pid)
    expect(Process.wait2(pid).last.signaled?).to be(true)
  ensure
    end_group(pid) if pid
  end
end
