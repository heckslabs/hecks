module Hecks
  module Runtime
    class Dispatcher
      # What one dispatch settled on: the verb, the record, the events it announced, and what its
      # reactions did.
      Result = Struct.new(:verb, :instance, :events, :execution_plan, :persistence_outcome,
                          :refused_reactions, :blocking_reactions, :reaction_defects,
                          keyword_init: true) do
        # Lists the policy reactions this dispatch caused that the domain refused.
        #
        # A policy's trigger that a `given` or invariant refuses does not undo the command that
        # fired it, which has already persisted, so the outcome above stays a success. The
        # refusal is recorded here instead of vanishing into the reaction log.
        #
        # @return [Array<Hash{Symbol => Object}>] one `{ policy:, trigger:, reason: }` per refused
        #   reaction, oldest first; empty when every reaction was delivered
        def refused_reactions = self[:refused_reactions] || []

        # Lists the refused reactions that block the run, as opposed to a benign non-match.
        #
        # See `ReactionOutcome`: a refusal is benign when a sibling reaction to the same event
        # delivered another command on the same aggregate. `--wait` exits 1 on any that remain.
        #
        # @return [Array<Hash{Symbol => Object}>] the subset of `refused_reactions` that blocks
        def blocking_reactions = self[:blocking_reactions] || []

        # Lists the reactions that crashed, as opposed to being refused by the domain.
        #
        # A crash is warned and never re-raised, since the emitting command has persisted; it is
        # recorded here so `--wait` can fail on a chain that stopped halfway.
        #
        # @return [Array<Hash{Symbol => Object}>] `{ policy:, trigger:, reason:, error_class: }`
        #   per crashed reaction; empty when none crashed
        def reaction_defects = self[:reaction_defects] || []

        # Reads the identity of the record the dispatch settled on.
        #
        # @return [String, nil] the record's identity; nil for a port operation (no record)
        def id    = instance&.id

        # Reads the settled record's attributes as one Hash.
        #
        # @return [Hash{Symbol => Object}, nil] the record's state; nil for a port operation
        def state = instance&.to_h

        def to_s
          announced = events.empty? ? "no events" : events.map(&:name).join(", ")
          "#{verb} → #{instance.inspect} | #{announced}"
        end

        def inspect = "#<Result #{self}>"
      end
    end
  end
end
