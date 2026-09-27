require "rubocop"
# Not "rubocop/rspec/support": its global include of CopHelper collides with other specs'
# own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/sequential_hash_rename_in_loop"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::SequentialHashRenameInLoop do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's MSG without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # Fixture rebuilding the buggy `apply_renames` shape, so the cop is proven to catch it.
  it "flags the old buggy shape: one rename at a time against the same hash inside .each" do
    expect_offense(<<~RUBY)
      def apply_renames(state, renames)
        renames.each do |old_name, new_name|
          state[new_name] = state.delete(old_name)
          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `state[new] = state.delete(old)` inside a loop applies one rename at a time against the SAME hash it reads from — a swap (`{a: :b, b: :a}`) on `{a: 1, b: 2}` collapses to `{a: 1}` because the first rule's write clobbers the second rule's read target before it runs (the exact bug fixed for Lineage#apply_renames). Snapshot every old key's value FIRST, delete all old keys, then write all new keys, so the pass applies as one simultaneous permutation instead of a sequence of edits each stepping on the last.
        end
      end
    RUBY
  end

  it "flags the same shape on an ivar receiver, inside .each_pair" do
    expect_offense(<<~RUBY)
      def apply_renames(renames)
        renames.each_pair do |old_name, new_name|
          @state[new_name] = @state.delete(old_name)
          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `@state[new] = @state.delete(old)` inside a loop applies one rename at a time against the SAME hash it reads from — a swap (`{a: :b, b: :a}`) on `{a: 1, b: 2}` collapses to `{a: 1}` because the first rule's write clobbers the second rule's read target before it runs (the exact bug fixed for Lineage#apply_renames). Snapshot every old key's value FIRST, delete all old keys, then write all new keys, so the pass applies as one simultaneous permutation instead of a sequence of edits each stepping on the last.
        end
      end
    RUBY
  end

  it "flags the shape inside .map, nested one level under an if guard" do
    expect_offense(<<~RUBY)
      def apply_renames(state, renames)
        renames.map do |old_name, new_name|
          if state.key?(old_name)
            state[new_name] = state.delete(old_name)
            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `state[new] = state.delete(old)` inside a loop applies one rename at a time against the SAME hash it reads from — a swap (`{a: :b, b: :a}`) on `{a: 1, b: 2}` collapses to `{a: 1}` because the first rule's write clobbers the second rule's read target before it runs (the exact bug fixed for Lineage#apply_renames). Snapshot every old key's value FIRST, delete all old keys, then write all new keys, so the pass applies as one simultaneous permutation instead of a sequence of edits each stepping on the last.
          end
        end
      end
    RUBY
  end

  it "does not flag the NEW fixed apply_renames (snapshot-first, delete-then-write)" do
    expect_no_offenses(<<~RUBY)
      def apply_renames(state, renames)
        snapshot = renames.filter_map { |old_name, new_name| [old_name, new_name, state[old_name]] if state.key?(old_name) }
        snapshot.each { |old_name, _new_name, _value| state.delete(old_name) }
        snapshot.each { |_old_name, new_name, value| state[new_name] = value }
      end
    RUBY
  end

  it "does not flag the exact same shape when it is NOT inside a loop" do
    expect_no_offenses(<<~RUBY)
      def apply_rename(state, old_name, new_name)
        state[new_name] = state.delete(old_name)
      end
    RUBY
  end

  it "does not flag hash[]=/delete on DIFFERENT receivers inside a loop" do
    expect_no_offenses(<<~RUBY)
      def move_between(source, destination, keys)
        keys.each do |old_name, new_name|
          destination[new_name] = source.delete(old_name)
        end
      end
    RUBY
  end
end
