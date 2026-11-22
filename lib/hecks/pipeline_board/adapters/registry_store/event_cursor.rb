# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      class RegistryStore
        # The events of a store's log kept between refreshes, so a refresh reads only the events
        # recorded since the last one. It is the adapter's memory, never a source of truth: the log
        # rebuilds it whole whenever the registry differs or the log shrank, and it is unbounded by
        # design, like the log it follows. A store's log is the database's whole shared `events`
        # table, so the cursor is per database, not per aggregate, and each answer is a new array
        # so a reader still holding the previous one never sees it change.
        class EventCursor
          def initialize
            @kept = {}
          end

          # @param registry [Object] the registry the log was resolved from
          # @param key [Array] what is asked, such as `["Tickets", "Work"]`
          # @param repository [#events, #events_past, #event_count] the aggregate's store
          # @return [Array<Runtime::Event>] every event the log holds, oldest first
          def read(registry, key, repository)
            return repository.events.to_a unless repository.respond_to?(:events_past)

            owner, seen = @kept[key]
            seen = [] unless owner.equal?(registry) && seen.size <= repository.event_count
            @kept[key] = [registry, seen + repository.events_past(seen.size)]
            @kept[key].last
          end
        end
      end
    end
  end
end
