require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/checkout_gate"
require_relative "support/stand_in_checkout"

# The Gate port's adapter against a stand-in checkout whose launcher is a script: the adapter runs
# what the checkout holds and reads only whether it passed.
RSpec.describe Hecks::Adapters::CheckoutGate do
  include StandInCheckout

  def judge(directory) = described_class.new.judge(checkout: { value: directory })

  it "answers a report naming the checkout when its gate is green" do
    in_checkout(gate: :green) do |directory|
      expect(judge(directory)).to eq(report: { value: "gate green in #{directory}" })
    end
  end

  it "asks the checkout's own launcher for its quick gate" do
    in_checkout(gate: :green) do |directory|
      judge(directory)
      expect(File.read(File.join(directory, "asked")).strip).to eq("gate_run.gate! stage=quick --wait")
    end
  end

  it "refuses with the end of what a red gate printed" do
    in_checkout(gate: :red) do |directory|
      expect { judge(directory) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /gate red: the gate failed in .*rubocop: 1 offense/m)
    end
  end

  it "refuses a launcher that ends well without a completed run" do
    in_checkout(gate: :silent) do |directory|
      expect { judge(directory) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /gate red/)
    end
  end

  it "refuses a checkout that is not there" do
    absent = File.join(Dir.tmpdir, "hecks-checkout-gate-absent")
    expect { judge(absent) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /gate red/)
  end

  it "refuses a shipment that names no checkout" do
    expect { described_class.new.judge }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no checkout to judge/)
  end
end
