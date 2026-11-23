require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/machine_profiling"

# A machine that cannot say how much memory it has gets no derived resident cap: a cap of one
# would refuse every second resident, so the default stands until the machine can be measured.
RSpec.describe Hecks::Adapters::MachineProfiling do
  let(:silent) { ->(_command) { "" } }
  let(:meminfo) { File.join(Dir.mktmpdir("meminfo"), "meminfo") }

  def facts(path = "/nonexistent/meminfo") = described_class::Reading.new(run: silent, meminfo: path).facts

  it "derives no resident cap for a machine whose memory cannot be read" do
    expect(described_class.of("residents", 12, profile: facts)).to eq(12)
  end

  it "reads memory from the kernel's own listing when the OS tool does not answer" do
    File.write(meminfo, "MemTotal:       16384000 kB\nMemAvailable:    8192000 kB\n")
    expect(facts(meminfo).values_at(:memory_mb, :free_memory_mb)).to eq([16_000, 8_000])
  end
end
