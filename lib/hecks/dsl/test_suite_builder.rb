# Hecks::DSL::TestSuiteBuilder
#
# DSL entry point for `Hecks.behaviors "Pizzas" do ... end`. Collects
# a vision string and a list of `test "..." do ... end` blocks and
# builds a Structure::TestSuite.
#
# Sibling to BluebookBuilder — does NOT share its DSL surface. The
# behaviors grammar has only: vision, test.
#
#   suite = TestSuiteBuilder.new("Pizzas").tap do |b|
#     b.vision "Behavioral tests for the Pizzas domain"
#     b.test "CreatePizza sets name" do
#       tests "CreatePizza", on: "Pizza"
#       input name: "Margherita"
#       expect name: "Margherita"
#     end
#   end.build
#
require "hecks/dsl/test_builder"

module Hecks
  module DSL
    class TestSuiteBuilder
      def initialize(name)
        @name   = name
        @vision = nil
        @tests  = []
      end

      def vision(text)
        @vision = text
      end

      def test(description, &block)
        builder = TestBuilder.new(description)
        builder.instance_eval(&block) if block
        @tests << builder.build
      end

      def build
        BluebookModel::Structure::TestSuite.new(
          name: @name, vision: @vision, tests: @tests,
        )
      end
    end
  end
end
