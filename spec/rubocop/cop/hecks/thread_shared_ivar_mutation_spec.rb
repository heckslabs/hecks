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
require_relative "../../../../lib/rubocop/cop/hecks/thread_shared_ivar_mutation"

# `RuboCop::RSpec::ExpectOffense`/`CopHelper` need RSpec required first — see
# `CopHelper`'s own `extend RSpec::SharedContext`, which blows up with an
# uninitialized-constant `NameError` if `rspec` (pulled in by `spec_helper`
# already, transitively, but named explicitly here since this spec would
# still make sense run in isolation) hasn't defined it yet.
# `Style/FormatStringToken` prefers `%<foo>s` over `%{foo}` — but
# `expect_offense`'s own `**replacements` mechanism (`format_offense`,
# rubocop/rspec/expect_offense.rb) matches the literal text `%{keyword}` in
# the source string via `gsub`, not real `Kernel#format` interpolation, so
# `%<class_name>s` would not be substituted at all here. The template form
# is this file's actual requirement, not a style lapse.
# rubocop:disable-next Style/FormatStringToken
RSpec.describe RuboCop::Cop::Hecks::ThreadSharedIvarMutation do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # `DisplayCopNames` defaults to true in a bare `RuboCop::Config.new` (it
  # comes from `config/default.yml`'s own `AllCops` section, not from
  # anything this repo's `.rubocop.yml` sets) — turned off here so the
  # offense message below matches this cop's own `MSG` verbatim, without
  # every expectation also needing to restate the `Hecks/
  # ThreadSharedIvarMutation: ` badge `MessageAnnotator` would otherwise
  # prepend.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  # THE TWO CLASSES THE USER NAMED, SCOPED BY SHORT CLASS NAME (see the
  # cop's own comment on why full-namespace resolution isn't attempted) —
  # `class Dispatcher` inside `module Hecks; module Runtime; ... end; end`
  # is exactly this codebase's own actual layout for both
  # `lib/hecks/runtime/dispatcher.rb` and `lib/hecks/runtime/registry.rb`.
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
      # `expect_no_offenses` (unlike `expect_offense`) takes no
      # `**replacements` — it never needs the `%{...}` substitution
      # machinery since there's no annotation line to keep aligned with a
      # variable-width name, so plain string interpolation stands in here.
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
  it_behaves_like "flags plain ivar mutation", "Registry"

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
