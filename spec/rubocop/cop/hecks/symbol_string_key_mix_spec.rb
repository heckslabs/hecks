require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/symbol_string_key_mix"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::SymbolStringKeyMix do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # The method guesses whether the hash it was handed is symbol- or string-keyed.
  SYMBOL_STRING_MIX_FIXTURE = <<~RUBY.freeze
    def era(settings)
      settings.key?(:era) ? settings[:era] : settings["era"]
                                             ^^^^^^^^^^^^^^^ `settings[:era]` and `settings["era"]` are both read here, so this method guesses whether the hash is symbol- or string-keyed. Read it through one helper, or normalize the keys once at the boundary.
    end
  RUBY

  SYMBOL_STRING_DIFFERENT_NAMES = <<~RUBY.freeze
    def names(settings)
      [settings[:era], settings["role"]]
    end
  RUBY

  SYMBOL_STRING_DIFFERENT_RECEIVERS = <<~RUBY.freeze
    def merge(left, right)
      [left[:era], right["era"]]
    end
  RUBY

  it "flags one method reading a name by symbol and by string" do
    expect_offense(SYMBOL_STRING_MIX_FIXTURE)
  end

  it "does not flag different names" do
    expect_no_offenses(SYMBOL_STRING_DIFFERENT_NAMES)
  end

  it "does not flag different receivers" do
    expect_no_offenses(SYMBOL_STRING_DIFFERENT_RECEIVERS)
  end

  it "does not flag the shared reader" do
    expect_no_offenses("def era(settings); IndifferentKey.read(settings, :era); end")
  end
end
