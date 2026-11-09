require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching/step_outcome"
require_relative "support/boot_notice_samples"

# The reason a launcher step records (and so the Work.yield! reason) is the command's own cause,
# never the runtime's boot notice that happened to print first.
RSpec.describe Hecks::Adapters::Dispatching::StepOutcome do
  include BootNoticeSamples

  def reason_of(out: "", err: "")
    result = Struct.new(:out, :err, :status) { def ok? = status.zero? }.new(out, err, 1)
    described_class.new(result).reason
  end

  def record_with(refusal_text) = JSON.generate("state" => { "refusal" => refusal_text })

  it "reads the cause from a refusal that carries notices after the divider" do
    composed = Hecks::BootNotices.compose("#{saga}\nno such command: x")

    expect(reason_of(out: record_with(composed))).to eq("no such command: x")
  end

  it "skips every known notice when it falls back to stderr", :aggregate_failures do
    expect(reason_of(err: "#{notices.join("\n")}\nthe real error\n")).to eq("the real error")
    expect(reason_of(err: "#{overlay}\n", out: "printed")).to eq("printed")
  end

  it "falls back to the notices when the command said nothing else" do
    expect(reason_of(err: "#{saga}\n")).to include("save_saga")
  end
end
