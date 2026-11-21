# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      class RegistryStore
        # Reads of an aggregate's event log from a position, so a reader that keeps its place asks
        # for the events it has not seen and not the whole log. Mixed into {RegistryStore}, which
        # supplies the lock, the registry and the aggregate lookup. The answers are not cached: a
        # position changes with every call.
        #
        # The saving belongs to a store whose adapter reads from a position (Sqlite reads only the
        # new rows); a store without one still cuts the whole log, as {#events} reads it.
        module EventTail
          # @param domain [String] a bluebook of the domain, such as `"Tickets"`
          # @param name [String] an aggregate of it, such as `"Work"`
          # @param position [Integer] how many events, from the oldest, the reader has seen; the
          #   count is of the store's whole log, which a Sqlite store shares across aggregates
          # @return [Array<Runtime::Event>] the events after those, oldest first; none when the
          #   store keeps no event log
          # @raise [Unavailable] when the registry cannot be read or does not declare the aggregate
          def events_past(domain, name, position)
            current = registry
            @lock.synchronize { tail(tailed(current, domain, name), position) }
          end

          # @param domain [String] a bluebook of the domain, such as `"Tickets"`
          # @param name [String] an aggregate of it, such as `"Work"`
          # @return [Integer] how many events the store's log holds, in the same count as the
          #   position {#events_past} takes; 0 when the store keeps no event log
          # @raise [Unavailable] when the registry cannot be read or does not declare the aggregate
          def event_count(domain, name)
            current = registry
            @lock.synchronize { counted_events(tailed(current, domain, name)) }
          end

          private

          def tailed(current, domain, name)
            aggregate = aggregate_in(current, domain, name)
            raise Unavailable, "#{label} declares no #{domain}.#{name}" unless aggregate

            current.repository(domain, aggregate)
          end

          def tail(repository, position)
            return repository.events_past(position).to_a if repository.respond_to?(:events_past)

            repository.respond_to?(:events) ? repository.events.to_a.drop(position) : []
          end

          def counted_events(repository)
            return repository.event_count if repository.respond_to?(:event_count)

            repository.respond_to?(:events) ? repository.events.to_a.size : 0
          end
        end
      end
    end
  end
end
