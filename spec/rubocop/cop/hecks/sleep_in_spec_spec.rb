require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/sleep_in_spec"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::SleepInSpec do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # A fixed sleep guesses how long another thread needs.
  it "flags a bare sleep" do
    expect_offense(<<~RUBY)
      sleep 0.2
      ^^^^^^^^^ A fixed `sleep` guesses how long another thread needs, so the example is either flaky or slow. Wait on the thread itself: a Queue, or `ThreadParking.wait_until_parked(thread)`.
    RUBY
  end

  it "flags Kernel.sleep" do
    expect_offense(<<~RUBY)
      Kernel.sleep(1)
      ^^^^^^^^^^^^^^^ A fixed `sleep` guesses how long another thread needs, so the example is either flaky or slow. Wait on the thread itself: a Queue, or `ThreadParking.wait_until_parked(thread)`.
    RUBY
  end

  it "does not flag waiting for a thread to park" do
    expect_no_offenses("ThreadParking.wait_until_parked(waiter)")
  end

  it "does not flag a method that merely shares the name" do
    expect_no_offenses("scheduler.sleep(1)")
  end
end
