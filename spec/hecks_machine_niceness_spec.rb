require "spec_helper"
require "hecks/hecks/adapters/machine_sampling"
require_relative "support/machine_beats"

# A Claude session or the daemon running niced (nice 15 or more) or clamped to Background (priority
# 4) runs on the efficiency cores. A beat counts them; the Delegate bluebook says when that is heard.
RSpec.describe "the machine's niceness" do
  include MachineBeats

  let(:table) do
    <<~PS
      10 0 31 /Users/me/.local/bin/claude daemon run
      11 15 31 claude bg-pty-host --bg-pty-host /tmp/x
      12 10 4 claude --bg work
      13 20 31 /usr/bin/ruby build
      14 10 31 claude bg-pty-host --bg-pty-host /tmp/y
    PS
  end
  let(:result) { Hecks::Adapters::Shell::Result.new(table, "", instance_double(Process::Status, success?: true)) }
  let(:shell) { instance_double(Hecks::Adapters::Shell, capture: result) }
  let(:marks) { Hecks::Adapters::MachineSampling::Marks::DEFAULTS }

  def heard(counts)
    names = beat_through(Array.new(counts.size) { gauge(60.0) }, niceness: counts)[:names]
    names.grep(/Processes(Niced|Eased)/)
  end

  it "counts Claude processes at nice 15 or priority 4, and no others" do
    expect(Hecks::Adapters::MachineSampling::Niceness.new(shell: shell).count(marks)).to eq(2.0)
  end

  it "hears the processes niced when a beat finds any" do
    expect(heard([0, 2])).to include("ProcessesNiced")
  end

  it "hears nothing niced when every beat finds none" do
    expect(heard([0, 0])).not_to include("ProcessesNiced")
  end

  it "hears the processes eased on a beat that finds none after a niced one" do
    expect(heard([2, 0]).last).to eq("ProcessesEased")
  end
end
