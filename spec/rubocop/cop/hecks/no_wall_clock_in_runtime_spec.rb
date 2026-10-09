require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/no_wall_clock_in_runtime"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::NoWallClockInRuntime do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # An event stamped from the wall clock cannot be reproduced by a replay.
  it "flags Time.now" do
    expect_offense(<<~RUBY)
      occurred_at = Time.now.utc.iso8601
                    ^^^^^^^^ `Time.now` reads the wall clock inside the runtime, so a replay cannot reproduce it. Declare `needs :now` on the command, or stamp an event with `Hecks::Runtime::Event.stamp`.
    RUBY
  end

  it "flags Date.today" do
    expect_offense(<<~RUBY)
      Date.today
      ^^^^^^^^^^ `Date.today` reads the wall clock inside the runtime, so a replay cannot reproduce it. Declare `needs :now` on the command, or stamp an event with `Hecks::Runtime::Event.stamp`.
    RUBY
  end

  it "does not flag the stamping seam" do
    expect_no_offenses("occurred_at = Event.stamp")
  end

  it "does not flag Time.at, which is not a clock read" do
    expect_no_offenses("Time.at(epoch).utc")
  end
end
