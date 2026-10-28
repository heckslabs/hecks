require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/behaviors"
require_relative "support/hecks_parse_binary"

# The Pizzas behaviors that a step can say, written as examples. A value made of parts (a pizza's
# price and size, a payment's cents) is named in words, and the behaviors runner dispatches each
# step as the role it names. Every example has to fail when its expectation is wrong, so a pass
# means something.
RSpec.describe "the Pizzas examples written as sentences", :io do
  include_context "with the hecks-parse binary"

  PIZZAS_DIR = File.expand_path("fixtures/sentence/pizzas", __dir__)
  PIZZAS_EXAMPLES = File.join(PIZZAS_DIR, "sentence_form.examples")
  LAST_TOPPING = "  And Remy adds a topping to it with topping \"Jalapeno\" and amount 1\n".freeze
  ONE_TOPPING = "  And Remy adds a topping to it with topping \"Basil\" and amount 1\n".freeze
  SMALL_PIZZA = "size \"small\"\n".freeze

  # Each example, a piece of its text, and what that piece becomes when its expectation is wrong.
  WRONG_EXPECTATIONS = [
    ["A new pizza is on the menu, available for sale", "the order is available", "the order is sold"],
    ["A pizza takes no more than ten toppings", LAST_TOPPING, ""],
    ["A pizza with no toppings cannot be bought", "#{SMALL_PIZZA}  When", "#{SMALL_PIZZA}#{ONE_TOPPING}  When"],
    ["Buying a pizza sells it", "the order is sold", "the order is available"],
    ["A payment that does not cover the price is refused", "amount 500 cents", "amount 1200 cents"],
    ["A new pizza is on the menu, available for sale", "its customer name is not set", "its customer name is \"Chris\""],
    ["A payment received through the gateway sells the pizza", "and amount 1200 cents\n  Then", "and amount 500 cents\n  Then"],
    ["A payment through the gateway that does not cover the price sells nothing", "and amount 500 cents\n  Then Pizza",
     "and amount 1200 cents\n  Then Pizza"],
    ["A payment through the gateway for a pizza with no toppings sells nothing", "#{SMALL_PIZZA}  When the payment",
     "#{SMALL_PIZZA}#{ONE_TOPPING}  When the payment"],
    ["A sold pizza is no longer available", "  And Chris purchases it with amount 1100 cents and customer name \"Chris\"\n", ""],
    ["Orders costing less than a ceiling are found", "ceiling 1000 cents", "ceiling 2000 cents"],
    ["An available order can be read field by field", "its name is \"Only One\"", "its name is \"Nobody\""]
  ].freeze
  EXAMPLE_NAMES = WRONG_EXPECTATIONS.map(&:first).uniq.freeze

  let(:scratch) { Dir.mktmpdir }
  let(:pizzas) { Hecks::Behaviors.run(PIZZAS_EXAMPLES) }

  after { FileUtils.remove_entry(scratch) }

  # Runs the examples from the scratch directory with `replace` swapped for `with`.
  def run_changed(replace, with)
    %w[sentence_form.bluebook sentence_form_behaviors.hecksagon].each do |file|
      FileUtils.cp(File.join(PIZZAS_DIR, file), scratch)
    end
    File.write(File.join(scratch, "sentence_form.examples"), File.read(PIZZAS_EXAMPLES).sub(replace, with))
    Hecks::Behaviors.run(File.join(scratch, "sentence_form.examples"))
  end

  it "parse" do
    expect(pizzas.parse_error).to be_nil
  end

  it "run each example" do
    expect(pizzas.runs.map(&:description)).to eq(EXAMPLE_NAMES)
  end

  it "all pass" do
    expect(pizzas.runs.map(&:status)).to all(eq(:pass)), pizzas.runs.map(&:message).compact.inspect
  end

  WRONG_EXPECTATIONS.each do |name, right, wrong|
    it "fail when '#{right.strip.lines.first.strip}' of '#{name}' is wrong" do
      statuses = run_changed(right, wrong).runs.to_h { |run| [run.description, run.status] }

      expect(statuses.fetch(name)).to eq(:fail)
    end
  end
end
