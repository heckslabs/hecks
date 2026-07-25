# Memory — a persistence adapter that keeps instances in a plain Hash.
#
# The sibling of Sqlite on the SAME persistence family: same `persisted_by`
# verb, same reply signal, different backing. Swapping one line in the hecksagon
# swaps the whole storage story, and the domain never notices.
#
# It carries no configuration, so it has no matching .world block — the bind
# alone is the entire wiring. Useful for tests and for aggregates whose state is
# not worth surviving a restart.
#
#   Hecks.hecksagon("Pizzas") { Pizzas::Pizza.persisted_by("Memory") }
module Hecksagain
  module Adapters
    class Memory
      attr_reader :aggregate

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @records   = {}
        @events    = []
      end

      def find(id) = @records[id.to_s]
      def all      = @records.values
      def count    = @records.size

      def save(instance)
        @records[instance.id.to_s] = instance
      end

      def record_event(event) = @events << event

      def events = @events
    end
  end
end
