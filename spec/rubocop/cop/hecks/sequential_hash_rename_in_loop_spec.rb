require "rubocop"
# NOT "rubocop/rspec/support" — see fallback_hash_lookup_spec.rb's identical
# comment: that file's top-level `RSpec.configure { config.include CopHelper;
# ... }` installs CopHelper's `registry` method onto EVERY example group the
# instant it's required, which collided with unrelated specs elsewhere in
# this suite that define their own `registry`. Requiring the two mixins
# directly and including them only in this describe block keeps this cop's
# specs fully working without leaking anything globally.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/sequential_hash_rename_in_loop"

# `RuboCop::RSpec::ExpectOffense`/`CopHelper` need RSpec required first — see
# `CopHelper`'s own `extend RSpec::SharedContext`, which blows up with an
# uninitialized-constant `NameError` if `rspec` (pulled in by `spec_helper`
# already, transitively, but named explicitly here since this spec would
# still make sense run in isolation) hasn't defined it yet.
RSpec.describe RuboCop::Cop::Hecks::SequentialHashRenameInLoop do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # See `spec/rubocop/cop/hecks/thread_shared_ivar_mutation_spec.rb` for why
  # this is turned off: without it every expectation below would also need
  # to restate the `Hecks/SequentialHashRenameInLoop: ` badge
  # `MessageAnnotator` prepends by default.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # THE EXACT SHAPE M27 SHIPPED WITH — `apply_renames` used to do this,
  # one rule at a time, before it was fixed (see the cop's own header and
  # `lib/hecks/ports/persistence/plugins/era/lineage.rb`'s own comment on
  # `apply_renames`). Reconstructed here as a fixture, not by reverting the
  # real (already-fixed) method — this spec proves the cop would have
  # caught the bug, not that the bug still exists.
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

  it "does not flag an unrelated #delete call whose result is not written back via []=" do
    expect_no_offenses(<<~RUBY)
      def drop_all(state, names)
        names.each do |name|
          state.delete(name)
        end
      end
    RUBY
  end

  it "does not flag an unrelated []= write inside a loop with no #delete involved" do
    expect_no_offenses(<<~RUBY)
      def defaults(state, backfills)
        backfills.each do |backfill|
          state[backfill.name] = backfill.default unless state.key?(backfill.name)
        end
      end
    RUBY
  end

  it "does not flag #store used instead of []= (out of this cop's exact scope)" do
    expect_no_offenses(<<~RUBY)
      def apply_renames(state, renames)
        renames.each do |old_name, new_name|
          state.store(new_name, state.delete(old_name))
        end
      end
    RUBY
  end
end
