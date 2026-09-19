require_relative "ir"

# The authoring surface for `Hecks.behaviors "Name" do ... end` — one
# `test "description" do ... end` block per case, `tests`/`setup`/`input`/
# `expect` inside. `instance_eval`-based, the same shape every other
# hecks DSL builder uses (`WorldBuilder`, `HecksagonBuilder`).
module Hecks
  module Behaviors
    # Raised at `Hecks.behaviors` build time — a missing `vision` or
    # `loads` line names the fix directly rather than failing later, deep
    # inside a boot, over a suite that was never going to be scoped.
    class Malformed < StandardError; end

    # The `test "description" do ... end` block's own receiver — collects
    # `tests`/`setup`/`input`/`expect` calls and builds a `TestCase` (ir.rb).
    # `validate_expect!` (private, below) is where a malformed or empty
    # `expect` is refused at build time rather than silently passing later.
    class TestCaseBuilder
      # @param description [String] the `test "description" do ... end` text
      def initialize(description)
        @description   = description
        @tests_command = nil
        @on_aggregate  = nil
        @kind          = :command
        @setups        = []
        @input         = {}
        @expect        = {}
      end

      # Names the command or query this test case exercises.
      #
      # @param command [String, Symbol] the verb's name, bare or dotted-qualified
      # @param on [String, Symbol, nil] the aggregate the verb is scoped to, when `command`
      #   is bare and the domain declares more than one aggregate of that verb name;
      #   `nil` when `command` is already dotted or unambiguous
      # @param kind [Symbol] `:command` or `:query`, which runner (`Expectations#run_command`
      #   / `#run_query`) this test is checked against
      # @return [void]
      def tests(command, on: nil, kind: :command)
        @tests_command = command
        @on_aggregate  = on
        @kind          = kind
      end

      # Records one setup dispatch to run, in order, before the tested verb.
      #
      # @param command [String, Symbol] the setup command's name
      # @param kwargs [Hash{Symbol => Object}] the command's facts, passed through as `args`
      # @return [void]
      def setup(command, **kwargs)
        @setups << TestSetup.new(command: command, args: kwargs)
      end

      # Merges facts into the tested verb's own arguments.
      #
      # @param kwargs [Hash{Symbol => Object}] facts merged into the existing input
      # @return [Hash{Symbol => Object}] the input Hash after the merge
      def input(**kwargs)  = @input.merge!(kwargs)

      # Merges assertions the test must satisfy after the tested verb runs.
      #
      # @param kwargs [Hash{Symbol => Object}] expectations merged into the existing set;
      #   recognised keys include `ok:`, `refused:`, `emits:`, `count:`, and any field name
      # @return [Hash{Symbol => Object}] the expectation Hash after the merge
      def expect(**kwargs) = @expect.merge!(kwargs)

      # Builds the `TestCase` this block declared, refusing one with no tested verb or no
      # `expect`.
      #
      # @return [Behaviors::TestCase] the built test case
      # @raise [Malformed] if `tests` was never called, or `validate_expect!` refuses the
      #   declared expectation
      def build
        unless @tests_command
          raise Malformed, "test #{@description.inspect} never calls `tests` — " \
                           "say which command or query this example exercises"
        end

        validate_expect!

        TestCase.new(description: @description, tests_command: @tests_command,
                     on_aggregate: @on_aggregate, kind: @kind,
                     setups: @setups, input: @input, expect: @expect)
      end

      private

      # Closes the silent-pass paths a free-form `expect(**kwargs)` merge
      # otherwise leaves open: a test with no `expect` at all asserts
      # nothing and passes whenever dispatch doesn't raise; `count:` on a
      # command and `emits:` on a query are each read by neither runner
      # (Expectations#run_command/#run_query), so they're accepted here
      # and then silently ignored at run time. Checking both at build
      # time, not in the runners, makes them errors on the file that
      # wrote them rather than green checks nobody questions.
      def validate_expect!
        if @expect.empty?
          raise Malformed, "test #{@description.inspect} has no `expect` — say what this " \
                           "example proves (ok:, refused:, emits:, count:, or a field name)"
        end

        if @kind == :command && @expect.key?(:count)
          raise Malformed, "test #{@description.inspect}: `expect count:` only applies to " \
                           "queries — a command has no row count to check"
        end

        if @kind == :query && @expect.key?(:emits)
          raise Malformed, "test #{@description.inspect}: `expect emits:` only applies to " \
                           "commands — a query never dispatches, so it never emits"
        end
      end
    end

    # The top-level `Hecks.behaviors "Name" do ... end` receiver — collects
    # `vision`/`loads`/`test` calls and builds a `BehaviorsSuite` (ir.rb),
    # refusing to build one missing either `vision` or `loads` (`#build`).
    class BehaviorsBuilder
      # @param name [String] the suite's name, as passed to `Hecks.behaviors`
      # @param source_path [String] the `.behaviors` file's own path; `loads` resolves
      #   against its directory, and it is kept for error messages
      def initialize(name, source_path:)
        @name        = name
        @source_path = source_path
        @source_dir  = File.dirname(source_path)
        @vision      = nil
        @loads       = nil
        @tests       = []
      end

      # Records the suite's one-line vision statement.
      #
      # @param text [String] what this suite is examples of
      # @return [String] `text`, unchanged
      def vision(text) = @vision = text

      # Records which files this suite boots before running its tests, resolved to
      # absolute paths.
      #
      # Relative to this `.behaviors` file, never to the filesystem's cwd
      # or a same-stem convention — scope is a fact this file declares,
      # not one a runner infers.
      #
      # @param paths [Array<String>] file paths, relative to this `.behaviors` file
      # @return [void]
      def loads(*paths)
        @loads = paths.map { |path| File.expand_path(path, @source_dir) }
      end

      # Declares one test case, evaluating its block against a fresh `TestCaseBuilder`.
      #
      # @param description [String] the case's description
      # @yield the block declaring `tests`, `setup`, `input` and `expect`, evaluated
      #   against a `TestCaseBuilder`
      # @return [void]
      # @raise [Malformed] if the block's own `build` refuses it (no tested verb, or an
      #   invalid `expect`)
      def test(description, &block)
        builder = TestCaseBuilder.new(description)
        builder.instance_eval(&block) if block
        @tests << builder.build
      end

      # Builds the `BehaviorsSuite` this block declared, refusing one with no `vision` or
      # no `loads`.
      #
      # @return [Behaviors::BehaviorsSuite] the built suite
      # @raise [Malformed] if `vision` or `loads` was never called
      def build
        unless @vision
          raise Malformed, "#{@source_path}: no `vision \"...\"` — say in one line " \
                           "what this suite is examples of"
        end
        unless @loads
          raise Malformed, "#{@source_path}: no `loads \"...\"` — a behaviors file " \
                           "must declare exactly which files to boot"
        end

        BehaviorsSuite.new(name: @name, vision: @vision, loads: @loads,
                           tests: @tests, path: @source_path)
      end

      # Builds a `BehaviorsSuite` from `Hecks.behaviors "Name" do ... end`'s own block, in
      # one call.
      #
      # @param name [String] the suite's name
      # @param source_path [String] the `.behaviors` file's own path
      # @yield the block declaring `vision`, `loads` and each `test`, evaluated against
      #   the new builder
      # @return [Behaviors::BehaviorsSuite] the built suite
      # @raise [Malformed] if the block declares no `vision`, no `loads`, a test with no
      #   tested verb, or a test with an invalid `expect`
      def self.build(name, source_path:, &block)
        builder = new(name, source_path: source_path)
        builder.instance_eval(&block) if block
        builder.build
      end
    end
  end
end
