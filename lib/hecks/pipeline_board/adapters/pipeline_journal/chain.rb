# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Turns an event-trace report into board rows: the event, each policy that reacted with the
      # outcome of its delivery and the command it reached, and the events that followed on the same
      # record (the ones the command emitted, read from the journal's own order).
      module Chain
        FOLLOWING = 3

        private

        def chained(report)
          events = JSON.parse(JSON.generate(report)).fetch("events", [])
          events.map.with_index { |entry, index| row(entry, events.drop(index + 1)) }
        end

        def row(entry, later)
          event = entry["event"]
          { key: "journal:#{File.basename(entry["database"].to_s)}:#{event["id"]}", source: "journal",
            at: event["occurred_at"], aggregate: event["aggregate"], id: event["aggregate_id"],
            name: event["name"], reactions: entry["subscribers"].to_a.map { |sub| reaction(sub, event, later) } }
        end

        def reaction(sub, event, later)
          { policy: sub["consumer"].to_s.sub("policy:", ""), command: sub["reaches"].to_s,
            outcome: sub["outcome"].to_s, emitted: following(event, later) }
        end

        def following(event, later)
          same = later.map { |entry| entry["event"] }.select { |other| other["aggregate_id"] == event["aggregate_id"] }
          same.first(FOLLOWING).map { |other| other["name"] }
        end
      end
    end
  end
end
