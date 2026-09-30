require_relative "refusal_wording"

module Hecks
  module Runtime
    # Tells a refused policy reaction that blocks a run from one that is a benign non-match.
    #
    # A policy pair such as `RecordTheMatch` / `RecordTheDrift` reacts to one event with two
    # commands on one aggregate, each `given`-gated so exactly one applies; the other is refused
    # by design and the run passed. A refusal is benign when another reaction to the same event
    # delivered a different command on the same aggregate: an alternative took over. It is also
    # benign when a creating command reports the record already exists (a re-run's idempotent
    # registration: the record the run wanted is there). Every other refusal (a release's
    # `Accept` refused by a dirty tree, with no alternative) blocks the outcome. A crash
    # (`defect`) is never a refusal and is warned where it happens.
    module ReactionOutcome
      module_function

      # Picks the refused reactions that block the run.
      #
      # @param entries [Array<Hash>] every reaction one dispatch caused, delivered or not; keys
      #   are Symbols (local) or Strings (a remote host's JSON)
      # @return [Array<Hash{Symbol => Object}>] `{ policy:, trigger:, reason: }` per blocker
      def blocking(entries)
        rows = Array(entries).map { |entry| entry.transform_keys(&:to_sym) }
        rows.select { |row| row[:delivered] == false && !row[:defect] }
            .reject { |row| RefusalWording.already_exists?(row[:reason]) }
            .reject { |row| rows.any? { |other| alternative?(row, other) } }
            .map { |row| row.slice(:policy, :trigger, :reason) }
      end

      # Whether `other` delivered a different command on the aggregate `refused` targeted, in
      # answer to the same event.
      def alternative?(refused, other)
        other[:delivered] == true && other[:on] == refused[:on] &&
          other[:trigger] != refused[:trigger] &&
          aggregate_of(other[:trigger]) == aggregate_of(refused[:trigger])
      end

      # The `Domain::Aggregate` part of a `Domain::Aggregate.Command` trigger.
      def aggregate_of(trigger) = trigger.to_s.split(".").first
    end
  end
end
