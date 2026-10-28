require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/behaviors"
require_relative "support/hecks_parse_binary"

# A command named by several words reads in a step as its first word and the rest: `Create Pizza`
# is `creates a pizza` and `Add Topping` is `adds a topping to it`. The behaviors runner dispatches
# them as the roles the steps name, and a wrong expectation has to fail.
RSpec.describe "examples whose commands are named by several words", :io do
  include_context "with the hecks-parse binary"

  SHOP_DIR = File.expand_path("fixtures/sentence_examples/shop", __dir__)
  SHOP_EXAMPLE_NAMES = ["A topping goes on a pizza before the order is closed",
                        "The base form of the verb reads the same",
                        "A closed order cannot be closed again",
                        "Only a chef puts a topping on (Sam)"].freeze

  let(:scratch) { Dir.mktmpdir }
  let(:shop) { Hecks::Behaviors.run(File.join(SHOP_DIR, "shop.examples")) }

  after { FileUtils.remove_entry(scratch) }

  # Runs the Shop examples from the scratch directory with `replace` swapped for `with`.
  def run_changed(replace, with)
    FileUtils.cp(File.join(SHOP_DIR, "shop.bluebook"), File.join(scratch, "shop.bluebook"))
    File.write(File.join(scratch, "shop.examples"), File.read(File.join(SHOP_DIR, "shop.examples")).sub(replace, with))
    Hecks::Behaviors.run(File.join(scratch, "shop.examples"))
  end

  it "parse" do
    expect(shop.parse_error).to be_nil
  end

  it "run each example" do
    expect(shop.runs.map(&:description)).to eq(SHOP_EXAMPLE_NAMES)
  end

  it "all pass" do
    expect(shop.runs.map(&:status)).to all(eq(:pass)), shop.runs.map(&:message).compact.inspect
  end

  it "fail when an expectation is wrong, so a pass means something" do
    wrong = run_changed("Then the order is closed\n  And OrderClosed", "Then the order is open\n  And OrderClosed")

    expect(wrong.runs.first.status).to eq(:fail)
  end

  it "are refused, naming the wordings that work, for an object no command reads as" do
    refused = run_changed("creates a pizza", "creates a piza")

    expect(refused.parse_error).to include("'creates a piza' is not a command here. A step can say: creates a pizza")
  end
end
