require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require_relative "support/stand_in_checkout"

# The gate a landing asks: the adapter the booted project bound to the Gate port, judged against a
# stand-in checkout with a launcher of its own.
RSpec.describe Hecks::Adapters::GitLanding::BoundGate do
  include StandInCheckout

  let(:registry) { boot_hecks_in_memory.registry }

  # A registry that binds no adapter to any port.
  def unbound = Struct.new(:adapters).new({})

  it "answers nothing when the adapter Hecks binds judges the worktree green" do
    in_checkout(gate: :green) do |directory|
      expect(described_class.new(registry).refusal(directory)).to be_nil
    end
  end

  it "answers the adapter's own refusal when the worktree is red" do
    in_checkout(gate: :red) do |directory|
      expect(described_class.new(registry).refusal(directory)).to match(/gate red: .*rubocop: 1 offense/m)
    end
  end

  it "refuses by name a project that binds no gate, and never passes it" do
    in_checkout(gate: :green) do |directory|
      expect { described_class.new(unbound).refusal(directory) }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements the Gate port/)
    end
  end

  it "refuses a landing made with no booted project, which has no gate to ask" do
    in_checkout(gate: :green) do |directory|
      expect(described_class.new(nil).refusal(directory)).to include("no gate")
    end
  end
end
