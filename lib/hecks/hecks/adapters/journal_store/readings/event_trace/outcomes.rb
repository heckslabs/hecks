# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # What became of one event for one listener. The outbox row for the pair is the record:
          # its status (`delivered`, `pending`, `claimed`, `failed`, `refused`) and, for a refusal
          # or failure, its reason. Where no row exists, a later event the listener's trigger
          # emits is read as delivery (`evidence: "inferred_event"`); else it is `no record`.
          class Outcomes
            # @param registry [Runtime::Registry] a described registry
            # @param rows [Array<Hash>] outbox rows from the event's database
            # @param events [Array<Hash>] the events traced, to look for what a trigger emitted
            def initialize(registry, rows, events)
              @registry = registry
              @held = rows.map { |row| row.merge("event" => JSON.parse(row["event"].to_s)) }
                          .group_by { |row| [row["consumer"], *held_key(row["event"])] }
              @peers = events.group_by { |event| held_key(event, "aggregate_id") }
              @events = events
            end

            # @param event [Hash] a recorded event
            # @param subscriber [Hash] a listener description from {Subscribers}
            # @return [Hash] `outcome`, `evidence` and, when known, `reason`
            def for(event, subscriber)
              row = row_for(event, subscriber[:consumer])
              return from_row(row) if row

              emitted?(event, subscriber) ? { outcome: "delivered", evidence: "inferred_event" } : none
            end

            private

            def none = { outcome: "no record", evidence: "none" }

            def from_row(row)
              { outcome: row["status"], evidence: "outbox", reason: row["error"] }.compact
            end

            # The same event can be recorded twice in one second (a ring of reactions), so rows and
            # events of one identity pair off from the newest end: the log shows the newest events
            # and each has had one row per listener.
            def row_for(event, consumer)
              peers = @peers.fetch(held_key(event, "aggregate_id"), [])
              rows = @held.fetch([consumer, *held_key(event, "aggregate_id")], [])
              slot = rows.size - (peers.size - peers.index(event))
              rows[slot] if slot >= 0
            end

            def held_key(event, id = "id") = [event["name"], event[id].to_s, event["occurred_at"].to_s]

            def emitted?(event, subscriber)
              names = emitted_by(subscriber[:reaches])
              @events.any? { |later| later["id"].to_i > event["id"].to_i && names.include?(later["name"]) }
            end

            def emitted_by(verb)
              command = command_of(verb)
              Array(command&.emits).map { |name| Naming.unqualified(name.to_s) }
            end

            def command_of(verb)
              domain, aggregate, name = Naming.split_verb(verb)
              held = @registry.bluebook(domain)&.aggregate(aggregate) if name
              held&.commands&.find { |command| command.name == name }
            end
          end
        end
      end
    end
  end
end
