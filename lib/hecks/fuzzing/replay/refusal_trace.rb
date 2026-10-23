module Hecks
  module Fuzzing
    module Replay
      # Everything a refused dispatch must leave as it found it: stored records, journal entries,
      # events, reactions, saga advances and outbox rows. Read before every dispatch and again
      # after a refusal, so `Properties.refusals_leave_no_trace` can compare the two.
      module RefusalTrace
        module_function

        # What a dispatch could change, read off the live runtime.
        #
        # @param runtime [Hecks::Runtime] the booted runtime a step dispatches against
        # @return [Hash] `instances:`, `journal:`, `events:`, `reactions:`, `sagas:` and `outbox:`
        def snapshot(runtime)
          { instances: Replay.snapshot_instances(runtime), journal: journal(runtime.registry),
            events: runtime.events.size, reactions: runtime.reactions.size, sagas: runtime.sagas.size,
            outbox: runtime.outbox.rows.map(&:delivery_id) }
        end

        # Each append-only repository's entries, keyed by `"Domain::Aggregate"`; a repository
        # that keeps no journal is left out.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @return [Hash{String => Array<Array>}] `[operation, id, state]` per entry
        def journal(registry)
          registry.bluebooks.each_with_object({}) do |(domain, bluebook), out|
            bluebook.aggregates.each do |aggregate|
              repository = registry.repository(domain, aggregate)
              next unless repository.is_a?(Ports::Persistence::AppendOnly)

              out["#{domain}::#{aggregate.name}"] = repository.entries.map { |e| [e.operation, e.id, e.state] }
            end
          end
        end
      end
    end
  end
end
