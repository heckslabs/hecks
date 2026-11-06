# frozen_string_literal: true

require "json"
require "time"
require_relative "../journal_store/readings/event_trace/stores"
require_relative "../journal_store/readings/event_trace/sqlite_reader"

module Hecks
  module Adapters
    class IterationWatch
      # The events the sqlite stores of a registry hold, read-only and oldest first. A store that is
      # not sqlite, or not there yet, contributes nothing: a Memory domain keeps no log to read.
      class Log
        # One event of the log.
        #
        # @!attribute [r] name
        #   @return [String] the bare event name
        # @!attribute [r] aggregate_id
        #   @return [String] the identity of the record that emitted it
        # @!attribute [r] payload
        #   @return [Hash] what the event carried
        # @!attribute [r] at
        #   @return [Time] when it occurred
        # @!attribute [r] text
        #   @return [String] every string in the payload, to look a name up in
        Event = Struct.new(:name, :aggregate_id, :payload, :at, :text)

        # Most recent events read from each store.
        LIMIT = 5000

        STORES = JournalStore::Readings::EventTrace::Stores
        # The reader asks a selection for an event name, a run and a count: all events, the newest LIMIT.
        SELECTION = Struct.new(:event, :run, :last, :database).new(nil, nil, LIMIT, nil)

        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # @return [Array<Event>] the events of every sqlite store, oldest first
        def events
          return [] unless @registry

          stores.flat_map { |store| read(store) }.sort_by { |event| event.at.to_f }
        end

        private

        def stores = STORES.of(@registry).select { |store| store.kind == :sqlite }

        def read(store)
          reader = JournalStore::Readings::EventTrace::SqliteReader.open(store.key)
          reader ? reader.events(SELECTION).map { |row| event(row) } : []
        ensure
          reader&.close
        end

        def event(row)
          payload = JSON.parse(row["payload"].to_s)
          Event.new(row["name"], row["aggregate_id"].to_s, payload, moment(row["occurred_at"]), strings(payload).join(" "))
        rescue JSON::ParserError
          Event.new(row["name"], row["aggregate_id"].to_s, {}, moment(row["occurred_at"]), "")
        end

        def moment(text)
          Time.iso8601(text.to_s)
        rescue ArgumentError
          Time.at(0)
        end

        def strings(node)
          case node
          when Hash then node.values.flat_map { |inner| strings(inner) }
          when Array then node.flat_map { |inner| strings(inner) }
          else [node.to_s]
          end
        end
      end
    end
  end
end
