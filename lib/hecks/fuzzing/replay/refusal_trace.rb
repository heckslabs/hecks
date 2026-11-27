module Hecks
  module Fuzzing
    module Replay
      # Everything a refused dispatch must leave as it found it: stored records, journal entries,
      # events, reactions, saga advances and outbox rows. Read before every dispatch and again
      # after a refusal, so `Properties.refusals_leave_no_trace` can compare the two.
      module RefusalTrace
        module_function

        # The Refusal member's own aggregate: the fact a refusal leaves is not a change to refuse.
        RECORDER = "Refusal::CommandRefusal".freeze

        # @param event [Runtime::Event] an emitted event
        # @return [Boolean] whether it is the `CommandRefused` fact the dispatcher records
        def recorded?(event) = event.name.to_s == "CommandRefused"

        # @param domain [String, Symbol] a booted bluebook's name
        # @return [Boolean] whether it is the member that holds the recorder's aggregate
        def recorder?(domain) = domain.to_s == RECORDER.split("::").first

        # What a dispatch could change, read off the live runtime.
        #
        # @param runtime [Hecks::Runtime] the booted runtime a step dispatches against
        # @return [Hash] `instances:`, `journal:`, `events:`, `reactions:`, `sagas:` and `outbox:`
        def snapshot(runtime)
          { instances: Replay.snapshot_instances(runtime).reject { |key, _| key.start_with?(RECORDER) },
            journal: journal(runtime.registry), events: runtime.events.count { |event| !recorded?(event) },
            reactions: runtime.reactions.size, sagas: runtime.sagas.size,
            outbox: outbox_ids(runtime.outbox) }
        end

        # The delivery ids of every row the outbox holds.
        #
        # @param outbox [#rows] the runtime's outbox
        # @return [Array<String>] each row's `delivery_id`, in row order
        def outbox_ids(outbox) = outbox.rows.map(&:delivery_id)

        # Each append-only repository's entries, keyed by `"Domain::Aggregate"`; a repository
        # that keeps no journal is left out.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @return [Hash{String => Array<Array>}] `[operation, id, state]` per entry
        def journal(registry)
          registry.bluebooks.each_with_object({}) do |(domain, bluebook), out|
            bluebook.aggregates.each do |aggregate|
              repository = registry.repository(domain, aggregate)
              next if recorder?(domain)
              next unless repository.is_a?(Ports::Persistence::AppendOnly)

              out["#{domain}::#{aggregate.name}"] = repository.entries.map { |e| [e.operation, e.id, e.state] }
            end
          end
        end
      end
    end
  end
end
