require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/swallowed_rescue"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::SwallowedRescue do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # A crash and a missing record both read as the same literal.
  STANDARD_ERROR_FIXTURE = <<~RUBY.freeze
    def capable?
      adapter.capable?
    rescue StandardError
    ^^^^^^^^^^^^^^^^^^^^ This broad `rescue` answers `false` for any failure, so a crash reads as an ordinary "no result". Rescue the specific error, or use `Runtime::BestEffort.call(default) { ... }` for a deliberate guard.
      false
    end
  RUBY

  BARE_RESCUE_FIXTURE = <<~RUBY.freeze
    begin
      read
    rescue
    ^^^^^^ This broad `rescue` answers `nil` for any failure, so a crash reads as an ordinary "no result". Rescue the specific error, or use `Runtime::BestEffort.call(default) { ... }` for a deliberate guard.
      nil
    end
  RUBY

  NEXT_FIXTURE = <<~RUBY.freeze
    rows.each do |row|
      read(row)
    rescue StandardError
    ^^^^^^^^^^^^^^^^^^^^ This broad `rescue` answers `next` for any failure, so a crash reads as an ordinary "no result". Rescue the specific error, or use `Runtime::BestEffort.call(default) { ... }` for a deliberate guard.
      next
    end
  RUBY

  NAMED_ERROR_FIXTURE = <<~RUBY.freeze
    begin
      registry.adapter_class(name)
    rescue WiringError
      nil
    end
  RUBY

  HANDLED_FIXTURE = <<~RUBY.freeze
    begin
      read
    rescue StandardError => e
      log(e)
      nil
    end
  RUBY

  it "flags a rescue StandardError that answers false" do
    expect_offense(STANDARD_ERROR_FIXTURE)
  end

  it "flags a bare rescue that answers nil" do
    expect_offense(BARE_RESCUE_FIXTURE)
  end

  it "flags a broad rescue that answers next" do
    expect_offense(NEXT_FIXTURE)
  end

  it "does not flag a rescue of a named error" do
    expect_no_offenses(NAMED_ERROR_FIXTURE)
  end

  it "does not flag a broad rescue that does something with the failure" do
    expect_no_offenses(HANDLED_FIXTURE)
  end

  it "does not flag the BestEffort seam" do
    expect_no_offenses("BestEffort.call(false) { adapter.capable? }")
  end
end
