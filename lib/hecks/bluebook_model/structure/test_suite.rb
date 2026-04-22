# Hecks::BluebookModel::Structure::TestSuite
#
# A behavioral test suite for a domain. The IR produced by parsing a
# `_behavioral_tests.bluebook` file (Hecks.behaviors entry point).
#
# A TestSuite holds a collection of Tests. Each Test names what it's
# testing, optionally arranges via setup commands, acts via input,
# and asserts via expect.
#
# All tests are in-memory by definition — the runner instantiates the
# source domain's aggregates, replays setup, dispatches the input
# command/query, and compares final state to expect.
#
#   suite = TestSuite.new(name: "Pizzas", vision: "...", tests: [test])
#   suite.tests.first.tests_command   # => "CreatePizza"
#   suite.tests.first.input           # => { name: "Margherita" }
#   suite.tests.first.expect          # => { name: "Margherita" }
#
module Hecks
  module BluebookModel
    module Structure
      class TestSuite
        # @return [String] the source domain name (e.g., "Pizzas")
        attr_reader :name

        # @return [String, nil] human-readable summary of what this suite covers
        attr_reader :vision

        # @return [Array<Test>] the individual tests in this suite
        attr_reader :tests

        # @return [Array<String>] sibling bluebooks to load into the test domain
        #
        # Populated by `loads "pulse", "body"` in the `.behaviors` DSL. Each
        # entry is a bluebook name resolved to a file by the runner; the
        # resolved bluebook's aggregates/policies/value_objects merge into
        # the single Domain the tests execute against. Empty by default —
        # every pre-i43 `.behaviors` file parses with an empty list and
        # behaves identically to before.
        #
        # IR slot only in this commit: no consumer reads this field yet.
        attr_reader :loads

        def initialize(name:, vision: nil, tests: [], loads: [])
          @name = name
          @vision = vision
          @tests = tests
          @loads = loads
        end

        def ==(other)
          other.is_a?(TestSuite) &&
            name == other.name &&
            vision == other.vision &&
            tests == other.tests &&
            loads == other.loads
        end
        alias eql? ==

        def hash
          [name, vision, tests, loads].hash
        end
      end
    end
  end
end
