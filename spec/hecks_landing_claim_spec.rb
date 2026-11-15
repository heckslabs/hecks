# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/landing_claim"
require "hecks/hecks/adapters/checkout_gate"
require_relative "support/stand_in_checkout"

# One landing of a checkout at a time: a second landing that reaches the gate while the first holds
# the checkout's claim is refused before its gate runs, naming the first.
RSpec.describe Hecks::Adapters::LandingClaim do
  include StandInCheckout

  let(:dir) { Dir.mktmpdir("landing-claims") }
  let(:first) { claim(pid: 4242) }

  after { FileUtils.rm_rf(dir) }

  def claim(pid:)
    described_class.new(dir: dir, words: %w[Landing.carry! checkout.value=/w branch.value=b], pid: pid)
  end

  def refusal = Hecks::Adapters::ConsoleCapture::Failure

  it "refuses a second landing of a checkout the first holds, naming the first" do
    Dir.mktmpdir do |checkout|
      second = -> { claim(pid: 7).hold(checkout) { :ran } }
      first.hold(checkout) { expect(&second).to raise_error(refusal, /is being landed by pid 4242 \(Landing\.carry! checkout/) }
    end
  end

  it "lets a landing of another checkout run beside it" do
    Dir.mktmpdir do |one|
      Dir.mktmpdir { |two| expect(first.hold(one) { claim(pid: 7).hold(two) { :ran } }).to eq(:ran) }
    end
  end

  it "lets the next landing run once the first lets go" do
    Dir.mktmpdir do |checkout|
      first.hold(checkout) { :done }
      expect(claim(pid: 7).hold(checkout) { :ran }).to eq(:ran)
    end
  end

  it "refuses a second gate of a checkout whose gate is running, before the gate is asked", :aggregate_failures do
    in_checkout(gate: :green) do |checkout|
      second = -> { Hecks::Adapters::CheckoutGate.new(claim: claim(pid: 7)).judge(checkout: { value: checkout }) }
      first.hold(checkout) { expect(&second).to raise_error(refusal, /landing in flight: .*pid 4242/) }
      expect(File).not_to exist(File.join(checkout, "asked"))
    end
  end
end
