# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # What a trace asks of one open database, whichever engine holds it: the recorded events
          # that match a selection, the outbox rows that answer them, and the names that ever
          # occurred. The two engines differ only in how they bind a value, read a JSON field and
          # run a statement; a subclass supplies those.
          class Reader
            COLUMNS = "id, name, aggregate, aggregate_id, payload, occurred_at"

            # @param selection [Selection] which events to trace
            # @return [Array<Hash>] the newest matching events, oldest first
            def events(selection)
              return [] unless table?("events")

              where, binds = conditions(selection)
              sql = "SELECT #{COLUMNS} FROM events#{where} ORDER BY id DESC LIMIT #{selection.last.to_i}"
              run(sql, binds).reverse
            end

            # @return [Array<Hash>] every distinct `name`/`aggregate` pair the log holds
            def occurred
              table?("events") ? run("SELECT DISTINCT name, aggregate FROM events", []) : []
            end

            # @param events [Array<Hash>] events as {#events} answers them
            # @return [Array<Hash>] the outbox rows whose event has one of these identities
            def outbox_for(events)
              ids = events.map { |event| event["aggregate_id"].to_s }.uniq
              return [] if ids.empty? || !table?("hecks_outbox")

              sql = "SELECT id, consumer, status, error, event FROM hecks_outbox WHERE #{json("event", "id")} " \
                    "IN (#{(["?"] * ids.size).join(", ")}) ORDER BY id"
              run(sql, ids)
            end

            private

            def conditions(selection)
              parts = []
              binds = []
              add(parts, binds, "name = ?", selection.event)
              add(parts, binds, "(aggregate_id = ? OR #{json("payload", "run")} = ?)", selection.run, twice: true)
              [parts.empty? ? "" : " WHERE #{parts.join(" AND ")}", binds]
            end

            def add(parts, binds, clause, value, twice: false)
              return if value.to_s.empty?

              parts << clause
              binds.push(value.to_s, *(twice ? [value.to_s] : []))
            end
          end
        end
      end
    end
  end
end
