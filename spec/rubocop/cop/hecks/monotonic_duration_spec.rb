require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/monotonic_duration"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::MonotonicDuration do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # A wall-clock subtraction can go negative when the clock steps.
  it "flags Time.now minus a local" do
    expect_offense(<<~RUBY)
      elapsed = Time.now - started
                ^^^^^^^^^^^^^^^^^^ `Time.now - started` measures elapsed time on the wall clock, which can step. Take both ends from `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.
    RUBY
  end

  it "flags Time.now.to_f minus an instance variable" do
    expect_offense(<<~RUBY)
      Time.now.to_f - @started
      ^^^^^^^^^^^^^^^^^^^^^^^^ `Time.now - @started` measures elapsed time on the wall clock, which can step. Take both ends from `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.
    RUBY
  end

  it "does not flag an age against a file's stored mtime" do
    expect_no_offenses("Time.now - File.mtime(path) > KEEP")
  end

  it "does not flag a monotonic subtraction" do
    expect_no_offenses("Process.clock_gettime(Process::CLOCK_MONOTONIC) - started")
  end
end
