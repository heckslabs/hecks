# Hecks::DSL::FixturesBuilder
#
# DSL entry point for `Hecks.fixtures "Pizzas" do ... end` — the
# standalone fixtures file format. Sibling to BluebookBuilder and
# TestSuiteBuilder: its own file extension (.fixtures), its own
# surface, its own parity contract with the Rust parser.
#
# Surface (kept small):
#
#   Hecks.fixtures "Pizzas" do
#     aggregate "Pizza" do
#       fixture "Margherita", name: "Margherita", description: "Classic"
#       fixture "Pepperoni",  name: "Pepperoni",  description: "Spicy"
#     end
#     aggregate "Order" do
#       fixture "PendingOrder", customer_name: "Sample", quantity: 1
#     end
#   end
#
# Produces `Structure::FixturesFile` — a domain-name + list of
# `Structure::Fixture` records that match what the bluebook's inline
# form used to produce. Downstream consumers (heki seed loader,
# behavioral test setups) see the same shape; only the source file
# changed.
require "hecks/bluebook_model/structure/fixture"

module Hecks
  module DSL
    class FixturesBuilder
      def initialize(name)
        @name = name
        @fixtures = []
      end

      # Scope the inner `fixture` calls to one aggregate type. `name`
      # is the aggregate's PascalCase name, matching the source
      # bluebook's `aggregate "X" do`.
      def aggregate(name, &block)
        @current_aggregate = name.to_s
        instance_eval(&block) if block
        @current_aggregate = nil
      end

      # Declare a seed record for the current aggregate. `label` is the
      # fixture's logical name (stored on `Fixture#name`); kwargs are
      # the record's attribute values.
      def fixture(label, **attributes)
        return unless @current_aggregate
        @fixtures << BluebookModel::Structure::Fixture.new(
          name: label.to_s,
          aggregate_name: @current_aggregate,
          attributes: attributes,
        )
      end

      def build
        FixturesFile.new(name: @name, fixtures: @fixtures)
      end

      # IR shape returned by the builder. Same shape the Rust
      # `fixtures_ir::FixturesFile` produces, so parity tooling can
      # diff both directly.
      class FixturesFile
        attr_reader :name, :fixtures
        def initialize(name:, fixtures: [])
          @name = name
          @fixtures = fixtures
        end

        def ==(other)
          other.is_a?(FixturesFile) && name == other.name && fixtures == other.fixtures
        end
      end
    end
  end
end
