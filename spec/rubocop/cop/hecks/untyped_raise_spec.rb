require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/untyped_raise"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::UntypedRaise do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # A bare string raises a RuntimeError, which can only be rescued by rescuing everything.
  it "flags raise with only a string" do
    expect_offense(<<~RUBY)
      raise "no clock adapter bound"
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `raise` raises a bare `RuntimeError`, which a caller can only rescue by rescuing everything. Raise a named error class.
    RUBY
  end

  it "flags raise with only an interpolated string" do
    expect_offense(<<~'RUBY')
      raise "no adapter #{name}"
      ^^^^^^^^^^^^^^^^^^^^^^^^^^ `raise` raises a bare `RuntimeError`, which a caller can only rescue by rescuing everything. Raise a named error class.
    RUBY
  end

  it "flags an explicit RuntimeError" do
    expect_offense(<<~RUBY)
      raise RuntimeError, "no clock adapter bound"
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `raise` raises a bare `RuntimeError`, which a caller can only rescue by rescuing everything. Raise a named error class.
    RUBY
  end

  it "does not flag a named error class" do
    expect_no_offenses('raise WiringError, "no clock adapter bound"')
  end

  it "does not flag re-raising the rescued error" do
    expect_no_offenses("raise")
  end

  it "does not flag raising an error instance" do
    expect_no_offenses('raise WiringError.new("no clock adapter bound")')
  end
end
