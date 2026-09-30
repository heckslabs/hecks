require "rubocop"
# Not "rubocop/rspec/support": its global include of CopHelper collides with other specs'
# own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/thread_shared_ivar_mutation"

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
# `expect_offense`'s `**replacements` (`format_offense`,
# rubocop/rspec/expect_offense.rb) matches the literal text `%{keyword}` in
# the source via gsub, so the `%<keyword>s` form would not be substituted.
# rubocop:disable-next Style/FormatStringToken
RSpec.describe RuboCop::Cop::Hecks::ThreadSharedIvarMutation do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # The cop matches by short class name; Dispatcher and Registry live in Hecks::Runtime.
  shared_examples "flags plain ivar mutation" do |class_name|
    it "flags a plain assignment" do
      expect_offense(<<~RUBY, class_name: class_name)
        module Hecks
          module Runtime
            class %{class_name}
              def reenter
                @reaction_depth = 1
                ^^^^^^^^^^^^^^^^^^^ `@reaction_depth` is a plain instance variable mutated outside `initialize` on #{class_name}, which is shared across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the state genuinely must be shared.
              end
            end
          end
        end
      RUBY
    end

    it "flags an ||= mutation" do
      expect_offense(<<~RUBY, class_name: class_name)
        module Hecks
          module Runtime
            class %{class_name}
              def reenter
                @cache ||= {}
                ^^^^^^^^^^^^^ `@cache` is a plain instance variable mutated outside `initialize` on #{class_name}, which is shared across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the state genuinely must be shared.
              end
            end
          end
        end
      RUBY
    end

    it "flags an += mutation" do
      expect_offense(<<~RUBY, class_name: class_name)
        module Hecks
          module Runtime
            class %{class_name}
              def bump
                @count += 1
                ^^^^^^^^^^^ `@count` is a plain instance variable mutated outside `initialize` on #{class_name}, which is shared across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the state genuinely must be shared.
              end
            end
          end
        end
      RUBY
    end

    it "flags an in-place << mutation" do
      expect_offense(<<~RUBY, class_name: class_name)
        module Hecks
          module Runtime
            class %{class_name}
              def track(event)
                @seen << event
                ^^^^^^^^^^^^^^ `@seen` is a plain instance variable mutated outside `initialize` on #{class_name}, which is shared across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the state genuinely must be shared.
              end
            end
          end
        end
      RUBY
    end

    it "flags an in-place []= mutation" do
      expect_offense(<<~RUBY, class_name: class_name)
        module Hecks
          module Runtime
            class %{class_name}
              def remember(key, value)
                @cache[key] = value
                ^^^^^^^^^^^^^^^^^^^ `@cache` is a plain instance variable mutated outside `initialize` on #{class_name}, which is shared across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the state genuinely must be shared.
              end
            end
          end
        end
      RUBY
    end

    it "does not flag assignment inside initialize" do
      # `expect_no_offenses` takes no `**replacements`, so the name is interpolated.
      expect_no_offenses(<<~RUBY)
        module Hecks
          module Runtime
            class #{class_name}
              def initialize
                @reaction_depth = 0
                @cache = {}
              end
            end
          end
        end
      RUBY
    end

    it "allows the Thread.current-backed fix itself" do
      expect_no_offenses(<<~RUBY)
        module Hecks
          module Runtime
            class #{class_name}
              def reenter
                depth = Thread.current[:hecks_reaction_depth].to_i
                Thread.current[:hecks_reaction_depth] = depth + 1
              end
            end
          end
        end
      RUBY
    end
  end

  it_behaves_like "flags plain ivar mutation", "Dispatcher"

  it "does not flag plain ivar mutation in an unrelated class" do
    expect_no_offenses(<<~RUBY)
      module Hecks
        module Runtime
          class CommandInterpreter
            def call
              @count = 1
              @seen << :x
            end
          end
        end
      end
    RUBY
  end

  it "does not flag a local variable that merely looks like it (no @ sigil)" do
    expect_no_offenses(<<~RUBY)
      module Hecks
        module Runtime
          class Dispatcher
            def reenter
              depth = 1
              depth += 1
            end
          end
        end
      end
    RUBY
  end

  it "flags a plain ivar mutation nested inside a block within a non-initialize method" do
    expect_offense(<<~RUBY)
      module Hecks
        module Runtime
          class Registry
            def reset_runtime_state!
              [1, 2].each do |x|
                @count = x
                ^^^^^^^^^^ `@count` is a plain instance variable mutated outside `initialize` on Registry, which is shared across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded critical section (`Registry#saga_mutex`) if the state genuinely must be shared.
              end
            end
          end
        end
      end
    RUBY
  end
end
