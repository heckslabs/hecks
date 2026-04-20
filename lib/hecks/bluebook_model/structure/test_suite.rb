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

        def initialize(name:, vision: nil, tests: [])
          @name = name
          @vision = vision
          @tests = tests
        end

        def ==(other)
          other.is_a?(TestSuite) &&
            name == other.name &&
            vision == other.vision &&
            tests == other.tests
        end
        alias eql? ==

        def hash
          [name, vision, tests].hash
        end
      end
    end
  end
end
