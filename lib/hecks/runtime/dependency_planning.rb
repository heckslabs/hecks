require_relative "../bluebook/expression"

module Hecks
  module Runtime
    # Persistence-neutral facts derived from a command's semantic IR; it plans, never executes.
    module DependencyPlanning
      ATOMIC_PUT = :atomic_put
      TRANSACTIONAL_FALLBACK = :load_apply_validate_store

      Plan = Struct.new(
        :read_set,
        :write_set,
        :payload_read_set,
        :complete_state,
        :state_independent,
        :unresolved_dependencies,
        keyword_init: true
      ) do
        # Whether every owner field this command could touch is a known, deterministic write.
        #
        # @return [Boolean] `complete_state`
        def complete_state? = complete_state

        # Whether the command needs no prior state at all (implies `complete_state?`).
        #
        # @return [Boolean] `state_independent`
        def state_independent? = state_independent

        # Chooses the dispatch strategy the plan's proof and the adapter's capabilities allow.
        # An optimization is selected only when both are present.
        #
        # @param capabilities [Array<String, Symbol>] the repository's declared capabilities
        # @return [Symbol] `DependencyPlanning::ATOMIC_PUT` when the plan is complete,
        #   state-independent, and the adapter declares that capability;
        #   `DependencyPlanning::TRANSACTIONAL_FALLBACK` otherwise
        def strategy_for(capabilities: [])
          return TRANSACTIONAL_FALLBACK unless complete_state? && state_independent?
          return TRANSACTIONAL_FALLBACK unless capabilities.map(&:to_sym).include?(ATOMIC_PUT)

          ATOMIC_PUT
        end
      end
    end
  end
end

require_relative "dependency_planning/expression_reads"
require_relative "dependency_planning/analyzer"
