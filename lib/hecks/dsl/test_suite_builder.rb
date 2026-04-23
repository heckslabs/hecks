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
        @loads  = []
      end

      def vision(text)
        @vision = text
      end

      def test(description, &block)
        builder = TestBuilder.new(description)
        builder.instance_eval(&block) if block
        @tests << builder.build
      end

      # Declare sibling bluebooks to merge into the test domain.
      #
      #   loads "pulse", "body"
      #
      # Each name is a bluebook — the `.behaviors` runner resolves it
      # to a file, parses it, and merges its aggregates/policies/
      # value_objects into the single Domain tests execute against.
      # Append-only so multiple `loads` lines accumulate; declaration
      # order is preserved and mirrors the Rust parser's
      # `suite.loads.push` order, keeping Ruby/Rust parity byte-for-byte
      # on every `.behaviors` fixture.
      #
      # Validation — empty strings are rejected at DSL-build time so the
      # runner never tries to resolve the empty name to a file path.
      # A blank argument (after `to_s`) raises ArgumentError with the
      # full names list for context.
      #
      # No consumer in this commit; the IR field is populated so the
      # runtime merge-domain logic (commit 6) can read it.
      def loads(*names)
        normalized = names.map(&:to_s)
        if (blank = normalized.find { |n| n.strip.empty? })
          raise ArgumentError,
                "loads: bluebook name cannot be blank (got #{blank.inspect} " \
                "in #{normalized.inspect})"
        end
        @loads.concat(normalized)
      end

      def build
        BluebookModel::Structure::TestSuite.new(
          name: @name, vision: @vision, tests: @tests, loads: @loads,
        )
      end
    end
  end
end
