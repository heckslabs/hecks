# Hecks::Chapters::Spec
#
# Self-describing chapter for Hecks' testing infrastructure.
# Covers spec generation, in-memory loading, memory adapters,
# test helpers, server test support, and the canonical Pizza/Order
# test domain used across the test suite.
#
#   domain = Hecks::Chapters::Spec.definition
#   domain.aggregates.map(&:name)
#   # => ["TestHelper", "InMemoryLoader", "MemoryAdapter", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Spec
      def self.definition
        Hecks::DSL::DomainBuilder.new("Spec").tap { |b|
          b.aggregate "TestHelper" do
            description "Resets runtime state between tests: clears repos and event bus"
            command "Reset"
          end

          b.aggregate "InMemoryLoader" do
            description "Loads a domain into Ruby without disk I/O via RubyVM::InstructionSequence"
            command "Load" do
              attribute :domain, String
              attribute :mod, String
            end
          end

          b.aggregate "MemoryAdapter" do
            description "Generated in-memory repository with find, save, delete, all, count, query, clear"
            command "Generate" do
              attribute :aggregate, String
              attribute :domain_module, String
            end
          end

          b.aggregate "MemoryOutbox" do
            description "In-memory outbox for testing: store, poll, mark_published, clear"
            command "Store" do
              attribute :event, String
            end
            command "Poll"
            command "MarkPublished" do
              attribute :entry_id, String
            end
          end

          b.aggregate "EventBus" do
            description "In-memory pub/sub with ordered event log for test verification"
            command "Subscribe" do
              attribute :event_name, String
            end
            command "Publish" do
              attribute :event, String
            end
            command "Clear"
          end

          b.aggregate "InMemoryExecutor" do
            description "Fallback query executor filtering in-memory collections"
            command "Execute"
          end

          b.aggregate "SpecGenerator" do
            description "Composes 14 type-specific mixins to generate RSpec files from domain IR"
            command "GenerateSpecHelper"
          end

          b.aggregate "SpecHelpers" do
            description "Example value generation, argument building, and spec snippet builders"
            command "ExampleArgs" do
              attribute :thing, String
            end
            command "ExampleValue" do
              attribute :attr, String
            end
          end

          b.aggregate "SpecWriter" do
            description "Orchestrates writing all RSpec files to disk for a domain gem"
            command "GenerateSpecs" do
              attribute :root, String
              attribute :gem_name, String
            end
          end

          b.aggregate "ServerHelpers" do
            description "HTTP server test helpers: port allocation, readiness polling, form submission"
            command "FreePort"
            command "WaitForServer" do
              attribute :url, String
            end
            command "SubmitForm" do
              attribute :base_url, String
              attribute :form_path, String
            end
          end

          b.aggregate "Pizza" do
            description "A pizza with a name, description, and toppings. Demonstrates value objects, lists, validations, and queries."
            attribute :name, String
            attribute :description, String
            attribute :toppings, list_of("Topping")

            value_object "Topping" do
              description "A measured ingredient on a pizza. Immutable once created."
              attribute :name, String
              attribute :amount, Integer

              invariant "amount must be positive" do
                amount > 0
              end
            end

            validation :name, presence: true
            validation :description, presence: true

            command "CreatePizza" do
              description "Add a new pizza to the menu with a name and description"
              attribute :name, String
              attribute :description, String
            end

            query "ByDescription" do |desc|
              where(description: desc)
            end

            command "AddTopping" do
              description "Add a measured topping to an existing pizza"
              reference_to "Pizza", validate: :exists
              attribute :name, String
              attribute :amount, Integer
            end
          end

          b.aggregate "Order" do
            description "A customer order referencing a pizza. Demonstrates references, transitions, and collection proxies."
            attribute :customer_name, String
            attribute :items, list_of("OrderItem")
            reference_to "Pizza"

            attribute :status, String, default: "pending" do
              transition "CancelOrder" => "cancelled"
            end

            value_object "OrderItem" do
              description "A line item in an order with a quantity"
              attribute :quantity, Integer

              invariant "quantity must be positive" do
                quantity > 0
              end
            end

            validation :customer_name, presence: true

            command "PlaceOrder" do
              description "Place a new order for a pizza"
              attribute :customer_name, String
              reference_to "Pizza", validate: :exists
              attribute :quantity, Integer
            end

            command "CancelOrder" do
              description "Cancel a pending order, transitioning status to cancelled"
              reference_to "Order", validate: :exists
            end

            query "Pending" do
              where(status: "pending")
            end
          end

          Chapters.define_paragraphs(Spec, b)
        }.build
      end
    end
  end
end
