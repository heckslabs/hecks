require "spec_helper"
require "hecks/fuzzing"

RSpec.describe Hecks::Fuzzing::Properties::EngineGuarantees do
  let(:properties) { Hecks::Fuzzing::Properties }

  def trace(verb, refused:, before:, after:)
    { verb: verb, refused: refused, before: before, after: after }
  end

  let(:unchanged) { { instances: { "Pizzas::Order#1" => { status: "open" } }, events: 1 } }
  let(:changed)   { { instances: { "Pizzas::Order#1" => { status: "sold" } }, events: 2 } }

  describe "#refusals_leave_state_untouched" do
    it "passes when a refused dispatch changed nothing" do
      history = { dispatch_traces: [trace("Pizzas::Order.purchase", refused: true, before: unchanged, after: unchanged)] }
      expect(properties.refusals_leave_state_untouched(history)).to be(true)
    end

    it "names a refused dispatch that changed an instance" do
      history = { dispatch_traces: [trace("Pizzas::Order.purchase", refused: true, before: unchanged, after: changed)] }
      expect(properties.refusals_leave_state_untouched(history))
        .to include("refused Pizzas::Order.purchase left a trace", "instances changed", "events 1 -> 2")
    end

    it "makes no claim without traces" do
      expect(properties.refusals_leave_state_untouched({})).to be(true)
    end
  end

  describe "#state_changes_are_journaled" do
    it "passes when a changed instance came with an event" do
      history = { dispatch_traces: [trace("Pizzas::Order.purchase", refused: false, before: unchanged, after: changed)] }
      expect(properties.state_changes_are_journaled(history)).to be(true)
    end

    it "names a dispatch that changed state without an event" do
      silent = changed.merge(events: 1)
      history = { dispatch_traces: [trace("Pizzas::Order.purchase", refused: false, before: unchanged, after: silent)] }
      expect(properties.state_changes_are_journaled(history))
        .to eq("Pizzas::Order.purchase changed state without emitting an event")
    end

    it "ignores refused dispatches, which the other property covers" do
      history = { dispatch_traces: [trace("x", refused: true, before: unchanged, after: changed.merge(events: 1))] }
      expect(properties.state_changes_are_journaled(history)).to be(true)
    end
  end

  describe "against a real replay" do
    it "holds for the pizzas example, including its refused purchase" do
      steps = [
        { "verb" => "Pizzas::Order.create_pizza",
          "args" => { "name" => "Margherita", "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => "large" } } },
        { "verb" => "Pizzas::Order.purchase", "args" => { "customer_name" => "Chris", "amount" => { "cents" => 1200 } } }
      ]
      history = Hecks::Fuzzing::Replay.call(File.join(InMemoryDomain::ROOT, "examples/pizzas"), steps)

      expect(history[:dispatch_traces]).not_to be_empty
      expect(properties.refusals_leave_state_untouched(history)).to be(true)
      expect(properties.state_changes_are_journaled(history)).to be(true)
    end
  end
end
