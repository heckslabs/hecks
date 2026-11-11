# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class StallWatching
      # The opening lines of the event tap still waiting for their closing lines, one `Sighting`
      # row each, read against the `StallKind` rows. It reports facts only: how long each line
      # has waited and what its row allows. Whether that is a stall is `Stall.File`'s rule.
      class Sightings
        # @param kinds [Array<Hash>] the `StallKind` rows: `kind`, `aggregate`, `opens`,
        #   `closes`, `minutes`, `forgets`, `fixer`
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        def initialize(kinds, now)
          @kinds = kinds
          @now = now
        end

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Sighting` row per opening line no closing line followed,
        #   opened within its kind's window
        def rows(lines, run)
          @kinds.flat_map { |kind| unclosed(kind, lines).map { |subject, at| sighting(kind, subject, at, run) } }
                .select { |row| row[:waited] < row[:forgets] }
        end

        private

        # Each subject the kind's opening line named and no closing line has closed, with when it
        # first opened.
        def unclosed(kind, lines)
          mine = lines.select { |line| line["kind"] == "event" && line["aggregate"] == kind[:aggregate] }
          closed = subjects(mine, kind[:closes].to_s.split(",").map(&:strip))
          opened(mine, kind[:opens]).reject { |subject, _| subject.empty? || closed.include?(subject) }
        end

        # The first time each subject recorded the opening event.
        def opened(lines, event)
          lines.select { |line| line["event"] == event }
               .each_with_object({}) { |line, first| first[line["id"].to_s] ||= line["at"] }
        end

        def subjects(lines, events) = lines.select { |line| events.include?(line["event"]) }.map { |line| line["id"].to_s }

        def sighting(kind, subject, at, run)
          waited = [(@now - Time.iso8601(at.to_s).to_i) / 60, 0].max
          { id: run, stall: "stall-#{kind[:kind]}-#{subject}", stall_kind: kind[:kind], subject: subject,
            opened_at: at.to_s, waited: waited, minutes: kind[:minutes], forgets: kind[:forgets],
            fixer: kind[:fixer], title: title(kind, subject), detail: detail(kind, subject, at, waited) }
        end

        def title(kind, subject) = "#{kind[:kind]} stalled: #{kind[:aggregate]} #{subject}"

        def detail(kind, subject, at, waited)
          "#{kind[:aggregate]} #{subject} recorded #{kind[:opens]} at #{at} and no #{kind[:closes]} after " \
            "#{waited} minutes (#{kind[:minutes]} allowed). Fixer: #{kind[:fixer]}. #{move(kind)}"
        end

        # The kind's move, and the standing rule that no move stops a session.
        def move(kind) = "Move: #{kind[:move]} Never stop or kill a session."
      end
    end
  end
end
