module Hecks
  module DSL
    class DomainBuilder

      # Hecks::DSL::DomainBuilder::AclBuilder
      #
      # Collects translations for an anti-corruption layer.
      #
      #   anti_corruption_layer "Billing" do
      #     translate "Invoice", billing_id: :invoice_number
      #   end
      #
      class AclBuilder
        def initialize(acl)
          @acl = acl
        end

        def translate(type, **mappings)
          @acl[:translations] << { type: type.to_s, mappings: mappings }
        end
      end

      # Hecks::DSL::DomainBuilder::SagaStepBuilder
      #
      # DSL builder for a single saga step. Collects success/failure events
      # and compensation command within a block.
      #
      #   step "ReserveInventory" do
      #     on_success "InventoryReserved"
      #     on_failure "ReservationFailed"
      #     compensate "ReleaseInventory"
      #   end
      #
      class SagaStepBuilder
        def initialize(command)
          @command = command
          @on_success = nil
          @on_failure = nil
          @compensate = nil
        end

        def on_success(event)  = (@on_success = event)
        def on_failure(event)  = (@on_failure = event)
        def compensate(cmd)    = (@compensate = cmd)

        def build
          DomainModel::Behavior::SagaStep.new(
            command: @command,
            on_success: @on_success,
            on_failure: @on_failure,
            compensate: @compensate
          )
        end
      end

      # Hecks::DSL::DomainBuilder::SagaBuilder
      #
      # Collects steps, timeout, and on_timeout for a saga process manager.
      # Supports both block-based steps (new API) and keyword steps (legacy).
      #
      #   saga "OrderFulfillment" do
      #     step "ReserveInventory" do
      #       on_success "InventoryReserved"
      #       compensate "ReleaseInventory"
      #     end
      #     timeout "48h"
      #     on_timeout "CancelOrder"
      #   end
      #
      class SagaBuilder
        def initialize(name)
          @name = name
          @steps = []
          @timeout = nil
          @on_timeout = nil
        end

        def step(command, on_success: nil, on_failure: nil, &block)
          if block
            builder = SagaStepBuilder.new(command)
            builder.instance_eval(&block)
            @steps << builder.build
          else
            @steps << DomainModel::Behavior::SagaStep.new(
              command: command, on_success: on_success, on_failure: on_failure
            )
          end
        end

        def timeout(duration)   = (@timeout = duration)
        def on_timeout(command)  = (@on_timeout = command)

        def build
          DomainModel::Behavior::Saga.new(
            name: @name, steps: @steps,
            timeout: @timeout, on_timeout: @on_timeout
          )
        end
      end

      # Hecks::DSL::DomainBuilder::GlossaryBuilder
      #
      # Collects term preference rules and definitions for ubiquitous language.
      #
      #   glossary do
      #     define "aggregate", as: "A cluster of domain objects treated as a unit"
      #     prefer "stakeholder", not: ["user", "person"], definition: "Anyone with interest in the outcome"
      #   end
      #
      class GlossaryBuilder
        def initialize(rules)
          @rules = rules
        end

        def prefer(term, not: [], definition: nil)
          banned = binding.local_variable_get(:not)
          @rules << { preferred: term, banned: banned, definition: definition }
        end

        def define(term, as:)
          @rules << { preferred: term, banned: [], definition: as }
        end
      end

      # Hecks::DSL::DomainBuilder::ModuleBuilder
      #
      # Delegates aggregate creation to the parent domain builder
      # while tracking which aggregates belong to this module.
      #
      #   domain_module "PolicyManagement" do
      #     aggregate "GovernancePolicy" do ... end
      #   end
      #
      class ModuleBuilder
        attr_reader :aggregate_names

        def initialize(name, parent)
          @name = name
          @parent = parent
          @aggregate_names = []
        end

        def aggregate(name, description = nil, &block)
          @aggregate_names << name
          @parent.aggregate(name, description, &block)
        end
      end

    end
  end
end
