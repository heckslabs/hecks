require "spec_helper"
require_relative "support/idler_chain"

# A tick of the idle chain rolls the queue through the owner's switch, and the domain ends the
# chain: a stop, or beats past the limit the world allows.
RSpec.describe "a tick of the idle chain" do
  include IdlerChain

  before do
    @hecks = boot_hecks_in_memory
    answer_roll("held-a", 1)
  end

  it "consults the owner's switch to roll" do
    expect { tick(1) }.to(change { names.count("RollSwitchConsulted") }.by(1))
  end

  it "is refused once the beats pass the limit" do
    expect { tick(999) }.to raise_error(StandardError, /limit/)
  end

  it "is refused once the chain is stopped" do
    dispatch("Idler.Stop", idler: "idle", ending: { value: "over" })
    expect { tick(1) }.to raise_error(StandardError)
  end
end
