# frozen_string_literal: true

require "json"
require_relative "stores"
require_relative "sqlite_reader"
require_relative "postgres_reader"
require_relative "subscribers"
require_relative "outcomes"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # Which events to trace: by bare event name, by the run (a record's identity or the
          # `run` field of its payload), or the newest `last`; `database` keeps the stores whose
          # location contains the text.
          Selection = Struct.new(:event, :run, :last, :database)

          # The trace itself: per store, the events found, who listens to each and what became of
          # it; the events nobody listens to; the policies whose event never occurred.
          class Report
            NO_LOG = "Memory keeps no log: nothing was recorded to trace"

            # @param registry [Runtime::Registry] a described registry
            # @param selection [Selection] what to trace
            def initialize(registry, selection)
              @registry = registry
              @selection = selection
              @subscribers = Subscribers.new(registry)
            end

            # @return [Hash] `summary`, `stores`, `events`, `no_subscriber` and `never_occurred`
            def to_h
              read = Stores.of(@registry, only: @selection.database).map { |store| read_store(store) }
              events = read.flat_map { |entry| entry[:events] }
              never = never_occurred(read)
              { summary: Summary.line(read, events, never), stores: read.map { |entry| entry[:store] },
                events: events, no_subscriber: unheard(events), never_occurred: never }
            end

            private

            def unheard(events) = events.select { |row| row[:subscribers].empty? }.map { |row| row[:event] }

            def read_store(store)
              reader = connect(store)
              return { store: describe(store, unreadable(store)), events: [] } unless reader

              read_from(store, reader)
            ensure
              reader&.close
            end

            def unreadable(store) = store.kind == :none ? NO_LOG : "absent: no database yet"

            def read_from(store, reader)
              found = reader.events(@selection)
              outcomes = Outcomes.new(@registry, reader.outbox_for(found), found)
              { store: describe(store, "read", found.size), events: found.map { |e| row(store, e, outcomes) },
                occurred: reader.occurred }
            end

            def connect(store)
              case store.kind
              when :sqlite then SqliteReader.open(store.key)
              when :postgres then PostgresReader.open(store.name, store.settings)
              end
            end

            def describe(store, state, events = 0)
              { database: store.key, adapter: store.adapter, state: state, events: events }
            end

            def row(store, event, outcomes)
              subs = @subscribers.for_event(event["name"], event["aggregate"])
              { database: store.key, event: identity(event),
                subscribers: subs.map { |sub| sub.merge(outcomes.for(event, sub)) } }
            end

            def identity(event)
              event.slice("id", "name", "aggregate", "aggregate_id", "occurred_at").transform_keys(&:to_sym)
            end

            def never_occurred(read)
              return nil if read.none? { |entry| entry[:occurred] }

              seen = read.flat_map { |entry| entry[:occurred] || [] }
              @subscribers.policies_all.reject { |policy| occurred?(policy, seen) }.map { |p| p.slice(:consumer, :on) }
            end

            def occurred?(policy, seen)
              name = Naming.unqualified(policy[:on])
              qualifier = Naming.qualifier(policy[:on])
              seen.any? { |s| s["name"] == name && (qualifier.nil? || Naming.demodulise(s["aggregate"]) == qualifier) }
            end
          end
        end
      end
    end
  end
end
