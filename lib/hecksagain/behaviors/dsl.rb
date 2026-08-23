require_relative "ir"

# The authoring surface for `Hecks.behaviors "Name" do ... end` — one
# `test "description" do ... end` block per case, `tests`/`setup`/`input`/
# `expect` inside. `instance_eval`-based, the same shape every other
# hecksagain DSL builder uses (`WorldBuilder`, `HecksagonBuilder`).
module Hecksagain
  module Behaviors
    # Raised at `Hecks.behaviors` build time — a missing `vision` or
    # `loads` line names the fix directly rather than failing later, deep
    # inside a boot, over a suite that was never going to be scoped.
    class Malformed < StandardError; end

    class TestCaseBuilder
      def initialize(description)
        @description   = description
        @tests_command = nil
        @on_aggregate  = nil
        @kind          = :command
        @setups        = []
        @input         = {}
        @expect        = {}
      end

      def tests(command, on: nil, kind: :command)
        @tests_command = command
        @on_aggregate  = on
        @kind          = kind
      end

      def setup(command, **kwargs)
        @setups << TestSetup.new(command: command, args: kwargs)
      end

      def input(**kwargs)  = @input.merge!(kwargs)
      def expect(**kwargs) = @expect.merge!(kwargs)

      def build
        unless @tests_command
          raise Malformed, "test #{@description.inspect} never calls `tests` — " \
                           "say which command or query this example exercises"
        end

        TestCase.new(description: @description, tests_command: @tests_command,
                     on_aggregate: @on_aggregate, kind: @kind,
                     setups: @setups, input: @input, expect: @expect)
      end
    end

    class BehaviorsBuilder
      def initialize(name, source_path:)
        @name        = name
        @source_path = source_path
        @source_dir  = File.dirname(source_path)
        @vision      = nil
        @loads       = nil
        @tests       = []
      end

      def vision(text) = @vision = text

      # Relative to THIS `.behaviors` file, never to the filesystem's cwd
      # or a same-stem convention — scope is a fact this file declares,
      # not one a runner infers.
      def loads(*paths)
        @loads = paths.map { |path| File.expand_path(path, @source_dir) }
      end

      def test(description, &block)
        builder = TestCaseBuilder.new(description)
        builder.instance_eval(&block) if block
        @tests << builder.build
      end

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

      def self.build(name, source_path:, &block)
        builder = new(name, source_path: source_path)
        builder.instance_eval(&block) if block
        builder.build
      end
    end
  end
end
