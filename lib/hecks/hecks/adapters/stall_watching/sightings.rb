# frozen_string_literal: true

require "time"
require_relative "standing"
require_relative "openings"

module Hecks
  module Adapters
    class StallWatching
      # The opening lines of the event tap still waiting for their closing lines, one `Sighting`
      # row each, read against the `StallKind` rows. It reports facts only: how long each line
      # has waited and what its row allows. Whether that is a stall is `Stall.File`'s rule.
      class Sightings
        # @param kinds [Array<Hash>] the `StallKind` rows: `kind`, `aggregate`, `opens`,
        #   `closes`, `closed_by`, `evidence`, `minutes`, `forgets`, `fixer`
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @param evidence [#call] answers a kind's `evidence` read as one line, or nil; asked only
        #   for a line past its kind's minutes, so a young line reads nothing
        def initialize(kinds, now, evidence: ->(_kind) {})
          @kinds = kinds
          @now = now
          @evidence = evidence
        end

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Sighting` row per opening line no closing line followed,
        #   opened within its kind's window, not filed yet and whose run has not ended
        def rows(lines, run)
          standing = Standing.new(lines)
          pending(lines).reject { |kind, subject, _| handled?(standing, kind, subject) }
                        .map { |kind, subject, at| sighting(kind, subject, at, run) }
                        .select { |row| row[:waited] < row[:forgets] }
        end

        # @return [Array<Hash>] one `Abandoned` row per stall the tap shows filed and still
        #   unclosed whose run has ended, not abandoned already, with the ending event as its reason
        def abandoned(lines, run)
          standing = Standing.new(lines)
          pending(lines).filter_map do |kind, subject, _|
            stall = key(kind, subject)
            ended = standing.ending(kind, subject)
            reason(run, kind, subject, ended) if ended && standing.filed?(stall) && !standing.abandoned?(stall)
          end
        end

        private

        def pending(lines) = @kinds.flat_map { |kind| unclosed(kind, lines).map { |subject, at| [kind, subject, at] } }

        def key(kind, subject) = "stall-#{kind[:kind]}-#{subject}"

        # Filed already, or its run ended: a look emits nothing more for it.
        def handled?(standing, kind, subject)
          standing.filed?(key(kind, subject)) || standing.ending(kind, subject)
        end

        def reason(run, kind, subject, ended)
          { id: run, stall: key(kind, subject), subject: subject,
            reason: "#{kind[:aggregate]} #{subject} can no longer be answered: its run recorded #{ended}" }
        end

        # Each subject the kind's opening line named and no closing line has closed, with when it
        # first opened.
        def unclosed(kind, lines) = Openings.new(kind, lines).unclosed

        def sighting(kind, subject, at, run)
          waited = [(@now - Time.iso8601(at.to_s).to_i) / 60, 0].max
          { id: run, stall: key(kind, subject), stall_kind: kind[:kind], subject: subject,
            opened_at: at.to_s, waited: waited, minutes: kind[:minutes], forgets: kind[:forgets],
            fixer: kind[:fixer], title: title(kind, subject), detail: detail(kind, subject, at, waited) }
        end

        def title(kind, subject) = "#{kind[:kind]} stalled: #{kind[:aggregate]} #{subject}"

        def detail(kind, subject, at, waited)
          "#{kind[:aggregate]} #{subject} recorded #{kind[:opens]} at #{at} and no #{kind[:closes]} after " \
            "#{waited} minutes (#{kind[:minutes]} allowed). Fixer: #{kind[:fixer]}. #{seen(kind, waited)}#{move(kind)}"
        end

        # What the kind's `evidence` read says now, for a line past its minutes; empty otherwise.
        def seen(kind, waited)
          return "" unless kind[:evidence] && waited >= kind[:minutes].to_i

          line = @evidence.call(kind)
          line ? "#{line}. " : ""
        end

        # The kind's move, and the standing rule that no move stops a session.
        def move(kind) = "Move: #{kind[:move]} Never stop or kill a session."
      end
    end
  end
end
