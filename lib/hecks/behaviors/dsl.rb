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

      # Records which command or query this test exercises.
      #
      # @param command [String, Symbol] the command or query verb, bare or dotted FQN
      # @param on [String, Symbol, nil] the aggregate `command` is dispatched on, when
      #   `command` is not already a dotted FQN
      # @param kind [Symbol] `:command` or `:query`
      # @return [void]
      def tests(command, on: nil, kind: :command)
        @tests_command = command
        @on_aggregate  = on
        @kind          = kind
      end

      # Records one setup command to dispatch before the test itself runs.
      #
      # @param command [String, Symbol] the setup command's verb
      # @param kwargs [Hash{Symbol => Object}] the setup command's own arguments
      # @return [void]
      def setup(command, **kwargs)
        @setups << TestSetup.new(command: command, args: kwargs)
      end

      # Merges fields into the arguments the tested command or query is called with.
      #
      # @param kwargs [Hash{Symbol => Object}] argument names and values to merge in
      # @return [Hash{Symbol => Object}] the input Hash so far
      def input(**kwargs)  = @input.merge!(kwargs)

      # Merges fields into what this test expects of the tested dispatch.
      #
      # @param kwargs [Hash{Symbol => Object}] expectation keys (`ok:`, `refused:`,
      #   `emits:`, `count:`, or a field name) and their expected values
      # @return [Hash{Symbol => Object}] the expectation Hash so far
      def expect(**kwargs) = @expect.merge!(kwargs)

      # Builds the `TestCase` this builder collected.
      #
      # @return [TestCase] the built test case
      # @raise [Malformed] if `tests` was never called, `expect` is empty, or
      #   `expect` declares `count:` on a command or `emits:` on a query
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
      # @param name [String] the suite's declared name
      # @param source_path [String] the `.behaviors` file's own path
      def initialize(name, source_path:)
        @name        = name
        @source_path = source_path
        @source_dir  = File.dirname(source_path)
        @vision      = nil
        @loads       = nil
        @tests       = []
      end

      # Records the suite's one-line description of what it is examples of.
      #
      # @param text [String] the vision text
      # @return [String] `text`, unchanged
      def vision(text) = @vision = text

      # Relative to this `.behaviors` file, never to the filesystem's cwd
      # or a same-stem convention — scope is a fact this file declares,
      # not one a runner infers.
      #
      # @param paths [Array<String>] paths to the files this suite's domain boots
      #   from, relative to the `.behaviors` file
      # @return [void]
      def loads(*paths)
        @loads = paths.map { |path| File.expand_path(path, @source_dir) }
      end

      # Builds and records one test case.
      #
      # @param description [String] the test's own description
      # @yield the test's body, evaluated against a `TestCaseBuilder`
      # @return [void]
      # @raise [Malformed] if the test never calls `tests`, has no `expect`, or
      #   declares `count:` on a command or `emits:` on a query
      def test(description, &block)
        builder = TestCaseBuilder.new(description)
        builder.instance_eval(&block) if block
        @tests << builder.build
      end

      # Builds the `BehaviorsSuite` this builder collected.
      #
      # @return [BehaviorsSuite] the built suite
      # @raise [Malformed] if the suite declares no `vision` or no `loads`
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

      # Builds a suite in one call: constructs a builder, evaluates `block`
      # against it, and builds the result.
      #
      # @param name [String] the suite's declared name
      # @param source_path [String] the `.behaviors` file's own path
      # @yield the suite's body, evaluated against the new builder
      # @return [BehaviorsSuite] the built suite
      # @raise [Malformed] if the suite declares no `vision` or `loads`, or any of
      #   its `test` blocks is malformed
      def self.build(name, source_path:, &block)
        builder = new(name, source_path: source_path)
        builder.instance_eval(&block) if block
        builder.build
      end
    end
  end
end
