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

        # @return [Array<[String, StateTransition]>] ordered list of (command, transition)
        #   pairs. Multiple entries with the same command are allowed and preserved —
        #   each may have its own +:from+, enabling a command to advance through
        #   progressive states (e.g. AccumulateFatigue: alert → focused → normal → tired).
        #   Iterates exactly like a Hash: `transitions.each do |cmd, t| ... end` works.
        attr_reader :transitions

        # Creates a new Lifecycle state machine definition.
        #
        # @param field [Symbol, String] the attribute name tracking state. Converted to Symbol.
        # @param default [String, Symbol] the initial state value. Converted to String.
        # @param transitions [Array<[String, StateTransition]>, Hash{String => StateTransition}]
        #   command-to-transition pairs. Hash input is converted to Array for backward
        #   compatibility; Array input is preferred because it preserves order and
        #   allows repeated commands.
        #
        # @return [Lifecycle] a new Lifecycle instance
        def initialize(field:, default:, transitions: [], description: nil)
          @field = field.to_sym
          @default = default.to_s
          @transitions = transitions.is_a?(Hash) ? transitions.to_a : transitions
          @description = description
        end

        # @return [String, nil] human-readable description of this lifecycle
        attr_reader :description

        # Returns all unique states reachable in this lifecycle, including the default.
        #
        # @return [Array<String>] unique state values (e.g., ["draft", "approved", "archived"])
        def states
          all = [default]
          transitions.each do |_cmd, t|
            target = t.respond_to?(:target) ? t.target : t.to_s
            all << target
          end
          all.uniq
        end

        # Returns the target state for a given command. When multiple transitions exist
        # for the same command (each with a different +from+), pass +current_state+ to
        # pick the matching one; without it, the first-declared transition wins.
        #
        # @param command_name [String] the command name to look up
        # @param current_state [String, nil] the aggregate's current state
        # @return [String, nil]
        def target_for(command_name, current_state = nil)
          match = match_transition(command_name, current_state)
          match ? (match.respond_to?(:target) ? match.target : match.to_s) : nil
        end

        # Returns the required source state(s) for a given command.
        # When multiple transitions share the command name, +current_state+ disambiguates.
        #
        # @param command_name [String]
        # @param current_state [String, nil]
        # @return [String, Array<String>, nil]
        def from_for(command_name, current_state = nil)
          match = match_transition(command_name, current_state)
          match && match.respond_to?(:from) ? match.from : nil
        end

        # All transitions declared for a command (possibly several with distinct +from+).
        #
        # @param command_name [String]
        # @return [Array<StateTransition>]
        def transitions_for(command_name)
          transitions.select { |cmd, _| cmd == command_name.to_s }.map { |_, t| t }
        end

        private

        def match_transition(command_name, current_state)
          matches = transitions_for(command_name)
          return nil if matches.empty?
          return matches.first unless current_state
          matches.find { |t| applies_from?(t, current_state) } || matches.first
        end

        def applies_from?(t, current)
          return true unless t.respond_to?(:from) && t.from
          Array(t.from).map(&:to_s).include?(current.to_s)
        end
      end
    end
  end
end
