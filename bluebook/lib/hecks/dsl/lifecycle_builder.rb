module Hecks
  module DSL

    # Hecks::DSL::LifecycleBuilder
    #
    # DSL builder for state machine declarations on aggregates. Collects
    # command-to-state transitions and builds a Lifecycle IR object.
    #
    #   builder = LifecycleBuilder.new(:status, default: "draft")
    #   builder.transition "ApproveModel" => "approved"
    #   builder.transition "SuspendModel" => "suspended"
    #   lifecycle = builder.build
    #
    # Builds a DomainModel::Structure::Lifecycle from transition declarations.
    #
    # LifecycleBuilder defines a state machine on a single aggregate field.
    # Each transition maps a command name to a target state, with an optional
    # +:from+ constraint that restricts which source states are valid. The
    # runtime enforces these transitions at command dispatch time.
    #
    # Used inside +AggregateBuilder#lifecycle+ blocks.
    class LifecycleBuilder
      Structure = DomainModel::Structure

      include Describable

      # Initialize a lifecycle builder for the given state field with a default value.
      #
      # @param field [Symbol] the attribute that holds the state value (e.g. :status)
      # @param default [String] the initial state value for new aggregates (e.g. "draft")
      def initialize(field, default:)
        @field = field
        @default = default
        @transitions = {}
      end

      # Map a command name to a target state, with an optional :from constraint.
      #
      # When +:from+ is provided, the transition is only valid if the current
      # state matches (or is included in) the +:from+ value. Without +:from+,
      # the transition is valid from any state.
      #
      # @param mapping [Hash] a hash containing the command-to-state mapping and
      #   an optional +:from+ key. The non-:from entry maps a command name
      #   (String or Symbol) to a target state (String or Symbol). The +:from+
      #   value can be a single state or an Array of valid source states.
      # @return [void]
      #
      # @example Unconditional transition
      #   transition "ApproveModel" => "approved"
      #
      # @example Transition with source state constraint
      #   transition "PublishModel" => "published", from: "approved"
      #
      # @example Transition from multiple source states
      #   transition "ArchiveModel" => "archived", from: ["approved", "published"]
      def transition(mapping)
        from = mapping.delete(:from)
        mapping.each do |command_name, target_state|
          @transitions[command_name.to_s] = Structure::StateTransition.new(
            target: target_state.to_s, from: from
          )
        end
      end

      # Build and return the DomainModel::Structure::Lifecycle IR object.
      #
      # @return [DomainModel::Structure::Lifecycle] the fully built lifecycle IR object
      def build
        Structure::Lifecycle.new(
          field: @field, default: @default, transitions: @transitions,
          description: @description
        )
      end
    end
  end
end
