# frozen_string_literal: true

require "hecks/adapters/driven/memory"

module Hecks
  module Adapters
    class DecisionFiles < Memory
      # The two-sided relations, derived over the records read: a record is superseded or narrowed
      # by every record whose status line says it supersedes or narrows it, whether or not its own
      # line says so. A derivation, made here because a file states only its own side.
      module Relations
        PAIRS = { supersedes: :superseded_by, narrows: :narrowed_by }.freeze

        module_function

        # @param states [Array<Hash>] the records' states, each with `supersedes`, `superseded_by`,
        #   `narrows` and `narrowed_by` lists
        # @return [Array<Hash>] the same states, the inverse lists filled
        def derive(states)
          by_number = states.to_h { |state| [state[:adr][:value], state] }
          states.each do |state|
            PAIRS.each { |forward, inverse| add_inverse(by_number, state, forward, inverse) }
          end
          states
        end

        def add_inverse(by_number, state, forward, inverse)
          own = { value: state[:adr][:value] }
          state[forward].each do |target|
            other = by_number[target[:value]] or next
            other[inverse] << own unless other[inverse].include?(own)
          end
        end
      end
    end
  end
end
