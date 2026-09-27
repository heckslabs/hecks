require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/fallback_hash_lookup"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::FallbackHashLookup do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's MSG without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # A `||` fallback between symbol and string keys drops a stored `false`.
  it "flags the historical h[k.to_sym] || h[k] shape" do
    expect_offense(<<~RUBY)
      h[k.to_sym] || h[k]
      ^^^^^^^^^^^^^^^^^^^ `h[...] || h[...]` falls back to the second lookup whenever the first is falsy — but `||` cannot tell a genuinely stored `false` apart from a missing key, so a real `false` at `h[k.to_sym]` is silently discarded in favor of `h[k]` instead of being returned. Use `h.key?(k.to_sym) ? h[k.to_sym] : h[k]`, or a shared digger (see `key?` in `Hecks::QuerySpecification::FieldPath#read`), instead.
    RUBY
  end

  # Fixture rebuilding the shape field_path.rb#read once had, so the cop is proven to catch it.
  it "flags the exact shape field_path.rb#read used to have, reconstructed as a fixture" do
    expect_offense(<<~RUBY)
      module Hecks
        module QuerySpecification
          module FieldPath
            def self.read(current, segment)
              sym = segment.to_sym
              current[sym] || current[segment]
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `current[...] || current[...]` falls back to the second lookup whenever the first is falsy — but `||` cannot tell a genuinely stored `false` apart from a missing key, so a real `false` at `current[sym]` is silently discarded in favor of `current[segment]` instead of being returned. Use `current.key?(sym) ? current[sym] : current[segment]`, or a shared digger (see `key?` in `Hecks::QuerySpecification::FieldPath#read`), instead.
            end
          end
        end
      end
    RUBY
  end

  it "flags the same shape as the second operand of an outer &&" do
    expect_offense(<<~RUBY)
      enabled? && (h[a] || h[b])
                   ^^^^^^^^^^^^ `h[...] || h[...]` falls back to the second lookup whenever the first is falsy — but `||` cannot tell a genuinely stored `false` apart from a missing key, so a real `false` at `h[a]` is silently discarded in favor of `h[b]` instead of being returned. Use `h.key?(a) ? h[a] : h[b]`, or a shared digger (see `key?` in `Hecks::QuerySpecification::FieldPath#read`), instead.
    RUBY
  end

  it "does not flag an ordinary default value (rhs is not a bracket lookup)" do
    expect_no_offenses(<<~RUBY)
      value || default_value
    RUBY
  end

  it "does not flag a bracket lookup falling back to a plain default" do
    expect_no_offenses(<<~RUBY)
      hash[:timeout] || 30
    RUBY
  end

  it "does not flag two different receivers looked up by the same key" do
    expect_no_offenses(<<~RUBY)
      primary[key] || secondary[key]
    RUBY
  end
end
