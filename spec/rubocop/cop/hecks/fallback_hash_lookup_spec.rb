require "rubocop"
# NOT "rubocop/rspec/support" — that file's own top-level `RSpec.configure
# { |config| config.include CopHelper; ... }` installs CopHelper's `registry`
# method onto EVERY example group in the whole process the instant this file
# is required, not just this one. That collided in a real, reproducible way
# with unrelated specs elsewhere in this suite that also define their own
# `registry` (a `let(:registry)` or a same-named local var) — `bisect`
# confirmed the resulting failures as order-dependent, and isolating just
# this cop's own describe block (below) to only the two mixins it actually
# needs, `require_relative`'d directly instead of via that global-installing
# file, is the fix: CopHelper/ExpectOffense stay fully functional for THIS
# cop's own examples, and nothing leaks into any other spec file.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/fallback_hash_lookup"

# `RuboCop::RSpec::ExpectOffense`/`CopHelper` need RSpec required first — see
# `CopHelper`'s own `extend RSpec::SharedContext`, which blows up with an
# uninitialized-constant `NameError` if `rspec` (pulled in by `spec_helper`
# already, transitively, but named explicitly here since this spec would
# still make sense run in isolation) hasn't defined it yet.
RSpec.describe RuboCop::Cop::Hecks::FallbackHashLookup do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # `DisplayCopNames` defaults to true in a bare `RuboCop::Config.new` (it
  # comes from `config/default.yml`'s own `AllCops` section, not from
  # anything this repo's `.rubocop.yml` sets) — turned off here so the
  # offense message below matches this cop's own `MSG` verbatim, without
  # every expectation also needing to restate the `Hecks/
  # FallbackHashLookup: ` badge `MessageAnnotator` would otherwise prepend.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # THE EXACT HISTORICAL BUG SHAPE — a value that could arrive keyed
  # either by symbol or by string, read with a `||` fallback that silently
  # drops a genuinely stored `false` and returns the OTHER spelling's value
  # (usually `nil`) instead. This is the shape `lib/hecks/query_specification
  # /field_path.rb#read` was rewritten away from — see that method's own
  # comment ("`key?` first, never `||`").
  it "flags the historical h[k.to_sym] || h[k] shape" do
    expect_offense(<<~RUBY)
      h[k.to_sym] || h[k]
      ^^^^^^^^^^^^^^^^^^^ `h[...] || h[...]` falls back to the second lookup whenever the first is falsy — but `||` cannot tell a genuinely stored `false` apart from a missing key, so a real `false` at `h[k.to_sym]` is silently discarded in favor of `h[k]` instead of being returned. Use `h.key?(k.to_sym) ? h[k.to_sym] : h[k]`, or a shared digger (see `key?` in `Hecks::QuerySpecification::FieldPath#read`), instead.
    RUBY
  end

  # A REGRESSION FIXTURE matching the actual shape fixed in
  # `lib/hecks/query_specification/field_path.rb#read` before it was
  # rewritten to the `key?`-first form — reconstructed here (not by
  # reverting that file) so this cop is proven to catch it.
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

  it "flags the same shape on a method-call receiver, not just a local variable" do
    expect_offense(<<~RUBY)
      attributes[key.to_sym] || attributes[key]
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `attributes[...] || attributes[...]` falls back to the second lookup whenever the first is falsy — but `||` cannot tell a genuinely stored `false` apart from a missing key, so a real `false` at `attributes[key.to_sym]` is silently discarded in favor of `attributes[key]` instead of being returned. Use `attributes.key?(key.to_sym) ? attributes[key.to_sym] : attributes[key]`, or a shared digger (see `key?` in `Hecks::QuerySpecification::FieldPath#read`), instead.
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

  it "does not flag unrelated || uses with no bracket lookup on either side" do
    expect_no_offenses(<<~RUBY)
      a? || b?
    RUBY
  end

  it "does not flag a bracket lookup falling back to a method call" do
    expect_no_offenses(<<~RUBY)
      hash[:name] || compute_default_name
    RUBY
  end

  it "does not flag the already-fixed key?-first idiom itself" do
    expect_no_offenses(<<~RUBY)
      current.key?(sym) ? current[sym] : current[segment]
    RUBY
  end

  it "does not flag &&" do
    expect_no_offenses(<<~RUBY)
      hash[:a] && hash[:b]
    RUBY
  end
end
