# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/codebase/heavy_slots"

# While the owner has `signalbox_response` drive it, a heavy job waits on its own session kind's
# answer to the posted band (ADR 0222 law 3) instead of on memory alone: it starts, waits until the
# answer runs, gives up and runs anyway, or is not started at all when it is a helper sent home.
RSpec.describe Hecks::Adapters::Codebase::ResponseWait do
  let(:err) { StringIO.new }
  let(:tight) { { band: "tight", headroom: 5000, coders_fit: 1, gates_fit: 0 } }
  let(:fallback) { Struct.new(:said) { def wait(_job) = said }.new("memory note") }

  # @param signals [Array<Hash, nil>] the signal each read answers, the last repeated
  # @param answers [Array<String>] the table's answer each ask gives, the last repeated
  def wait_with(signals, answers, caller: "coder:item-7")
    now = 0
    new_wait(signals, answers, caller, clock: -> { now }, pause: ->(seconds) { now += seconds })
  end

  def new_wait(signals, answers, caller, **timing)
    table = Struct.new(:answers) { def answer(**) = answers.size > 1 ? answers.shift : answers.first }.new(answers)
    pressure = -> { signals.size > 1 ? signals.shift : signals.first }
    described_class.new(fallback: fallback, poll: 10, give_up: 120, base: { "HECKS_CALLER" => caller }, pressure: pressure,
                        table: table, err: err, **timing)
  end

  it "waits on memory as before while the signal is dark" do
    expect(wait_with([nil], ["running"]).wait("spec_batch")).to eq("memory note")
  end

  it "starts at once and names no wait when the kind's answer is to run" do
    expect(wait_with([tight], ["running"]).wait("spec_batch")).to eq("")
  end

  it "holds a deferring coder until its answer runs and names the wait" do
    note = wait_with([tight], %w[deferring deferring running]).wait("gate")
    expect(note).to eq("waited 20 s: pressure tight (Signalbox): 1 coders fit, 0 gates fit: a coder defers its heavy steps")
  end

  it "runs anyway once the wait gives up, and says so" do
    expect(wait_with([tight], ["deferring"]).wait("gate")).to eq(
      "pressure held gate for 120 s (pressure tight (Signalbox): 1 coders fit, 0 gates fit); gate runs anyway"
    )
  end

  it "stops waiting when the signal goes dark" do
    expect(wait_with([tight, tight, nil], ["waiting"]).wait("gate")).to start_with("waited 20 s:")
  end

  it "does not start a helper's job the pressure sends home" do
    expect { wait_with([tight], ["leaving"], caller: "reviewer:p-walk").wait("spec_batch") }
      .to raise_error(described_class::Left, /a helper finishes and leaves; spec_batch not started/)
  end

  it "is not the wait while the switch is off" do
    expect(described_class.of(File.expand_path("..", __dir__))).to be_nil
  end
end
