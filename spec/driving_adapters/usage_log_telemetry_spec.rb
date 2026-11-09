require "spec_helper"

# A run records how long its launcher took to reach the command, whether the boot was cold, and who
# ran it; `hecks usage` sums them, and lines written before the fields existed still count.
RSpec.describe Hecks::Adapters::Driving::UsageLog::Telemetry do
  let(:now) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

  around do |example|
    saved = ENV.to_h.slice("HECKS_CALLER", "CLAUDE_SESSION_ID")
    ENV.delete("HECKS_CALLER")
    ENV.delete("CLAUDE_SESSION_ID")
    example.run
    ENV.update(saved)
  end

  it "measures from the launcher's first line to the command" do
    stub_const("HECKS_LAUNCHED_AT", now - 1.5)

    expect(described_class.boot_ms(now)).to be_between(1499, 1501)
  end

  it "leaves boot_ms out when the launcher noted no start" do
    hide_const("HECKS_LAUNCHED_AT")

    expect(described_class.fields(now)).not_to have_key("boot_ms")
  end

  it "names the caller from HECKS_CALLER before the session id", :aggregate_failures do
    ENV["CLAUDE_SESSION_ID"] = "session-1"
    expect(described_class.caller_name).to eq("session-1")

    ENV["HECKS_CALLER"] = "coder-7"
    expect(described_class.caller_name).to eq("coder-7")
  end

  it "reports cold when this process judged a bluebook afresh", :aggregate_failures do
    cache = Hecks::Bluebook::MetaValidator::VerdictCache
    allow(cache).to receive(:misses).and_return(0, 2)

    expect(described_class.cold?).to be(false)
    expect(described_class.cold?).to be(true)
  end

  it "sums runs by caller and by boot temperature, reading old lines without the fields", :aggregate_failures do
    runs = [{ "caller" => "a", "cold" => true, "boot_ms" => 9000 }, { "caller" => "a", "cold" => false, "boot_ms" => 1200 },
            { "caller" => "a", "cold" => false, "boot_ms" => 1400 }, { "resolved" => "work.undone" }]
    text = described_class.lines(runs).join("\n")

    expect(text).to include("3  a", "1  unnamed", "1  cold  9000 ms median boot", "2  warm  1400 ms median boot")
  end

  it "prints no section when no run has the fields" do
    expect(described_class.lines([{ "resolved" => "work.undone" }])).to eq([])
  end
end
