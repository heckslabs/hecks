module Hecks
  module BluebookModel
    module Structure

      # Hecks::BluebookModel::Structure::Lifecycle
      #
      # State machine definition for an aggregate. Declares which field tracks
      # status, its default value, and which commands trigger which transitions.
      # Supports optional +from:+ constraints to enforce valid source states.
      #
      # Transitions are stored as a Hash keyed by command name. Each value is either:
      # - A simple String target state (e.g., "approved")
      # - A Hash with +:target+ and optional +:from+ keys for constrained transitions
      #
      # The lifecycle is consumed by the command runner at runtime to automatically
      # update the status field after a command succeeds, and to reject commands
      # when the aggregate is not in a valid source state.
      #
      #   Lifecycle.new(field: :status, default: "draft",
      #     transitions: {
      #       "ApproveModel" => { target: "approved", from: "draft" },
      #       "ArchiveModel" => "archived"
      #     })
      #
      class Lifecycle
        # @return [Symbol] the attribute name that tracks the aggregate's current state
        #   (e.g., :status, :state). Must correspond to an attribute on the aggregate.
        attr_reader :field

        # @return [String] the initial state value assigned when the aggregate is created
        #   (e.g., "draft", "pending", "new")
        attr_reader :default

        # @return [Hash{String => String, Hash}] a mapping of command names to their target states.
        #   Values are either a simple String (the target state) or a Hash with +:target+ and
        #   optional +:from+ keys. The +:from+ key constrains which source state(s) the command
        #   is valid from.
        attr_reader :transitions

        # Creates a new Lifecycle state machine definition.
        #
        # @param field [Symbol, String] the attribute name tracking state. Converted to Symbol.
        # @param default [String, Symbol] the initial state value. Converted to String.
        # @param transitions [Hash{String => String, Hash}] command-to-state mappings.
        #   Keys are command names (e.g., "ApproveModel"). Values are either a target state
        #   string or a Hash like +{ target: "approved", from: "draft" }+.
        #
        # @return [Lifecycle] a new Lifecycle instance
        def initialize(field:, default:, transitions: {}, description: nil)
          @field = field.to_sym
          @default = default.to_s
          @transitions = transitions
          @description = description
        end

        # @return [String, nil] human-readable description of this lifecycle
        attr_reader :description

        # Returns all unique states reachable in this lifecycle, including the default.
        # Useful for generating enum validations or state-related documentation.
        #
        # @return [Array<String>] unique state values (e.g., ["draft", "approved", "archived"])
        def states
          ([default] + transitions.values.map { |v| v.respond_to?(:target) ? v.target : v.to_s }).uniq
        end

        # Returns the target state for a given command name.
        # Extracts the target from either a simple string value or a Hash with +:target+.
        #
        # @param command_name [String] the command name to look up (e.g., "ApproveModel")
        #
        # @return [String, nil] the target state, or nil if no transition is defined for this command
        def target_for(command_name)
          entry = transitions[command_name]
          return nil unless entry
          entry.respond_to?(:target) ? entry.target : entry.to_s
        end

        # Returns the required source state for a given command name, if constrained.
        # Only returns a value when the transition uses the Hash form with a +:from+ key.
        #
        # @param command_name [String] the command name to look up (e.g., "ApproveModel")
        #
        # @return [String, nil] the required source state, or nil if unconstrained or no
        #   transition exists for this command
        def from_for(command_name)
          entry = transitions[command_name]
          return nil unless entry
          entry.respond_to?(:from) ? entry.from : nil
        end
      end
    end
  end
end
