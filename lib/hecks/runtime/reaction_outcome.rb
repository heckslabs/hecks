require_relative "refusal_wording"

module Hecks
  module Runtime
    # Tells a refused policy reaction that blocks a run from one that is a benign non-match.
    #
    # A policy pair such as `RecordTheMatch` / `RecordTheDrift` reacts to one event with two
    # commands on one aggregate, each `given`-gated so exactly one applies; the other is refused
    # by design and the run passed. A refusal is benign when another reaction to the same event
    # instance delivered a different command on the same aggregate: an alternative took over. It
    # is also benign when the creating command it triggered reports the record already exists (a
    # re-run's idempotent registration: the record the run wanted is there). Every other refusal
    # (a release's `Accept` refused by a dirty tree, with no alternative) blocks the outcome. A
    # crash (`defect`) is never a refusal: it is warned where it happens and listed by
    # `defects`.
    module ReactionOutcome
      # A reaction entry, with the identity of the event instance it answered, when known.
      Row = Struct.new(:fields, :event) do
        def delivered = fields[:delivered]
      end

      module_function

      # Picks the refused reactions that block the run.
      #
      # An alternative counts only when it answered the same event instance, which `event_of`
      # reads (an outbox uid, or the event object's id). Without it (a remote host's JSON carries
      # no event identity) the event's name is all there is to match.
      #
      # @param entries [Array<Hash>] every reaction one dispatch caused, delivered or not; keys
      #   are Symbols (local) or Strings (a remote host's JSON)
      # @param event_of [#call, nil] maps an entry, as given, to the event instance it answered
      # @return [Array<Hash{Symbol => Object}>] `{ policy:, trigger:, reason: }` per blocker
      def blocking(entries, event_of: nil)
        rows = Array(entries).map { |entry| Row.new(entry.transform_keys(&:to_sym), event_of&.call(entry)) }
        rows.select { |row| row.delivered == false && !row.fields[:defect] }
            .reject { |row| already_there?(row) }
            .reject { |row| rows.any? { |other| alternative?(row, other) } }
            .map { |row| row.fields.slice(:policy, :trigger, :reason) }
      end

      # Whether `row` is its own creating command reporting the record already exists.
      def already_there?(row)
        RefusalWording.already_exists?(row.fields[:reason], **creating(row.fields[:trigger]))
      end

      # Whether `other` delivered a different command on the aggregate `refused` targeted, in
      # answer to the same event.
      def alternative?(refused, other)
        other.delivered == true && same_event?(refused, other) &&
          other.fields[:trigger] != refused.fields[:trigger] &&
          aggregate_of(other.fields[:trigger]) == aggregate_of(refused.fields[:trigger])
      end

      # Whether both reactions answered one event: the same instance when both are known, else
      # the same event name.
      def same_event?(refused, other)
        return false unless other.fields[:on] == refused.fields[:on]

        refused.event.nil? || other.event.nil? || refused.event == other.event
      end

      # The `Domain::Aggregate` part of a `Domain::Aggregate.Command` trigger.
      def aggregate_of(trigger) = trigger.to_s.split(".").first

      # The command and aggregate a trigger names, spelled as the AlreadyExists sentence does.
      def creating(trigger)
        target, command = trigger.to_s.split(".", 2)
        return { command: target&.split("::")&.last } unless command

        { command: command.split(".").last, aggregate: target.split("::").last }
      end

      # Picks the reactions that crashed, which no refusal rule excuses.
      #
      # A chain that crashes halfway leaves its record short of the state the run was meant to
      # reach, so a caller that waits on the run must treat every one as a failure.
      #
      # @param entries [Array<Hash>] every reaction one dispatch caused, keys as for `blocking`
      # @return [Array<Hash{Symbol => Object}>] `{ policy:, trigger:, reason:, error_class: }`
      #   per crashed reaction
      def defects(entries)
        Array(entries).map { |entry| entry.transform_keys(&:to_sym) }
                      .select { |row| row[:defect] }
                      .map { |row| row.slice(:policy, :trigger, :reason, :error_class) }
      end
    end
  end
end
