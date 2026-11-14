# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Turns the event log's lines into board rows: one row per event, each with the policy
      # deliveries the log holds for it and the events that followed on the same record. A line
      # that carries its own `policy` is an event with its reaction; a line that is not JSON is
      # dropped.
      module Linking
        # How many later events of a record a reaction names as what it emitted.
        FOLLOWING = 3

        private

        def parse(lines) = lines.filter_map { |line| decode(line) }

        def decode(line)
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        def link(lines)
          rows = []
          twins = Hash.new(0)
          lines.each { |line| line["kind"] == "reaction" ? attach(rows, line) : rows << event_row(line, twins) }
          rows.each_with_index { |row, index| follow(row, rows.drop(index + 1)) }
        end

        # An event's key is what it is, with a count that tells apart two events alike in every
        # field. It does not hold the event's place among the lines read, so a line appended to
        # the log leaves the key of every earlier event as it was and a stream sends only the new.
        def event_row(data, twins)
          { key: key_of(data, twins), source: "tap",
            at: data["at"], aggregate: data["aggregate"], id: data["id"], name: data["event"], reactions: inline(data),
            links: data["links"].to_h, correlation: data["correlation"].to_h }.merge(payload(data))
        end

        def key_of(data, twins)
          what = "tap:#{data["at"]}:#{data["aggregate"]}:#{data["id"]}:#{data["event"]}"
          "#{what}:#{(twins[what] += 1) - 1}"
        end

        # The structured payload a line carries (a `TurnFinished` does); most lines carry none.
        def payload(data) = data["payload"].is_a?(Hash) ? { payload: data["payload"] } : {}

        def inline(data) = data["policy"] ? [reaction(data)] : []

        def reaction(data)
          { policy: data["policy"], command: data["command"].to_s, outcome: data["outcome"].to_s,
            emitted: Array(data["emitted"]) }
        end

        def attach(rows, line)
          row = rows.reverse.find { |held| held[:id].to_s == line["id"].to_s && held[:name] == bare(line["event"]) }
          row[:reactions] << reaction(line) if row
        end

        def bare(name) = name.to_s.split(".").last

        def follow(row, later)
          names = later.select { |other| other[:id] == row[:id] && other[:name] != row[:name] }.first(FOLLOWING)
          row[:reactions].each { |reaction| reaction[:emitted] = names.map { |other| other[:name] } if reaction[:emitted].empty? }
          row
        end
      end
    end
  end
end
