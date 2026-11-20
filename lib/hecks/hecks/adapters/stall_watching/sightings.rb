# frozen_string_literal: true

require "digest"
require "time"
require_relative "standing"
require_relative "openings"
require_relative "shared_subjects"
require_relative "run_names"
require_relative "settled_reads"
require_relative "settling"
require_relative "clearing"

module Hecks
  module Adapters
    class StallWatching
      # The opening lines of the event tap still waiting for their closing lines, one `Sighting`
      # row each, read against the `StallKind` rows. It reports facts only: how long each line
      # has waited and what its row allows. Whether that is a stall is `Stall.File`'s rule.
      class Sightings
        # The longest stall key, and so Work id, a look files.
        KEY_LIMIT = 120

        # @param kinds [Array<Hash>] the `StallKind` rows: `kind`, `aggregate`, `opens`,
        #   `closes`, `closed_by`, `evidence`, `minutes`, `forgets`, `fixer`
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @param evidence [#call] answers a kind's `evidence` read as one line, or nil; asked only
        #   for a line past its kind's minutes, so a young line reads nothing
        # @param settled_read [#call] answers a kind's `settled_read` for an opening line's links as
        #   what settled it, or nil ({SettledReads})
        def initialize(kinds, now, evidence: ->(_kind) {}, settled_read: ->(_kind, _links) {})
          @kinds = kinds
          @now = now
          @evidence = evidence
          @settled_read = settled_read
        end

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Sighting` row per opening line no closing line followed,
        #   opened within its kind's window, not filed yet, whose run has not ended and whose
        #   subject has not settled; a row a call for help clears ({Clearing}) is left out, so is
        #   a run started to answer a question ({RunNames#answerer?}), and so is a row whose
        #   `shares` group already holds its subject or its `cap` of open stalls ({SharedSubjects})
        def rows(lines, run)
          standing = Standing.new(lines)
          @names = RunNames.new(lines)
          entries = pending(lines, standing)
          SharedSubjects.new(entries, standing, method(:key), lines).keep(fileable(entries, standing, run))
        end

        # @return [Array<Hash>] one `Abandoned` row per stall the tap shows filed, opened within its
        #   kind's window, whose run has ended or whose subject has settled since it opened, not
        #   abandoned already, with the ending or settling line as its reason. A filed stall whose
        #   line has closed since is one of them: its closing line never closes its Work item.
        def abandoned(lines, run)
          standing = Standing.new(lines)
          pending(lines, standing, closed: true).filter_map do |entry|
            kind, subject, at = entry
            stall = key(kind, subject)
            next unless standing.filed?(stall) && !standing.abandoned?(stall) && recent?(kind, at)

            gone = gone(standing, entry)
            reason(run, kind, subject, gone) if gone
          end
        end

        # @return [Array<Hash>] one `Sighting` row per opening line no closing line followed, whose
        #   run has not ended and whose subject has not settled, filed or not, each naming the stall
        #   it was filed as (`filed`), how its row clears it (`cleared_by`) and its row's `folds`;
        #   {Impediments} keeps those past their minutes and folds them
        def open_lines(lines, run)
          standing = Standing.new(lines)
          @names = RunNames.new(lines)
          pending(lines, standing).reject { |entry| gone(standing, entry) }
                                  .map { |kind, subject, at, _| impediment(standing, kind, subject, at, run) }
        end

        private

        # The open lines a look may offer to `File`: cleared by their stall item, not handled, not
        # a run started to answer a question, in the window.
        def fileable(entries, standing, run)
          entries.reject { |entry| Clearing.help?(entry.first) || handled?(standing, entry) || answerer?(*entry) }
                 .map { |kind, subject, at, _| sighting(kind, subject, at, run) }
                 .select { |row| row[:waited] < row[:forgets] }
        end

        def impediment(standing, kind, subject, at, run)
          stall = key(kind, subject)
          sighting(kind, subject, at, run).merge(filed: standing.filed?(stall) ? stall : "", folds: kind[:folds].to_s)
        end

        def pending(lines, standing, closed: false)
          @kinds.flat_map do |kind|
            openings = Openings.new(kind, lines, closed: closed)
            open = openings.unclosed.reject { |subject, _| about?(kind, subject, openings.branch(subject)) }
            one_per_branch(kind, open, openings, standing).map do |subject, at|
              [kind, subject, at, openings.branch(subject), openings.links(subject)]
            end
          end
        end

        # One landing is one branch: of the open subjects that link the same branch, the one already
        # filed stands for the branch, else the latest; a resubmitted landing never files a second
        # item. Subjects that link no branch stand alone.
        def one_per_branch(kind, open, openings, standing)
          open.group_by { |subject, _| openings.branch(subject) }.flat_map do |branch, entries|
            next entries unless branch

            [entries.find { |subject, _| standing.filed?(key(kind, subject)) } || entries.max_by { |_, at| at.to_s }]
          end
        end

        # Whether the kind's `not_about` prefix names the subject or the branch its opening line
        # links: a stall item, and a stall session's own landing, are never one. A subject the
        # kind's `exempt` list names exactly is never one either: a standing run waits by design.
        def about?(kind, subject, branch)
          prefix = kind[:not_about].to_s
          exempt?(kind, subject) || (!prefix.empty? && [subject, branch.to_s].any? { |name| name.start_with?(prefix) })
        end

        def exempt?(kind, subject) = exempt_subjects(kind).include?(subject)

        def exempt_subjects(kind) = kind[:exempt].to_s.split(",").map(&:strip)

        # `stall-<kind>-<subject>`; past {KEY_LIMIT} characters the tail is a digest of the whole.
        def key(kind, subject)
          full = "stall-#{kind[:kind]}-#{subject}"
          return full if full.length <= KEY_LIMIT

          "#{full[0, KEY_LIMIT - 17]}-#{Digest::SHA256.hexdigest(full)[0, 16]}"
        end

        def answerer?(kind, subject, *) = @names&.answerer?(kind, subject)

        # Filed already, its run ended or its subject settled: a look emits nothing more for it.
        def handled?(standing, entry)
          standing.filed?(key(*entry.first(2))) || gone(standing, entry)
        end

        # Why no fixer is needed ({Settling}), for a pending `[kind, subject, at, branch, links]`.
        def gone(standing, entry) = Settling.new(standing, @settled_read).why(entry)

        def reason(run, kind, subject, gone)
          { id: run, stall: key(kind, subject), subject: subject,
            reason: "#{kind[:aggregate]} #{subject} can no longer be answered: #{gone}" }
        end

        # Whether an opening line is younger than its kind's window, so a look never drops the Work
        # item of a stall that is history.
        def recent?(kind, at) = waited(at) < kind[:forgets].to_i

        def waited(at) = [(@now - Time.iso8601(at.to_s).to_i) / 60, 0].max

        def sighting(kind, subject, at, run)
          waited = waited(at)
          stall = key(kind, subject)
          { id: run, stall: stall, stall_kind: kind[:kind], subject: subject, opened_at: at.to_s, waited: waited,
            minutes: kind[:minutes], forgets: kind[:forgets], fixer: kind[:fixer], title: title(kind, subject),
            detail: detail(kind, subject, at, waited), filed: "", count: 1, impediment: stall, cleared_by: Clearing.of(kind) }
        end

        def title(kind, subject) = "#{kind[:kind]} stalled: #{kind[:aggregate]} #{subject}"

        def detail(kind, subject, at, waited)
          "#{kind[:aggregate]} #{subject} recorded #{kind[:opens]} at #{at} and no #{kind[:closes]} after " \
            "#{waited} minutes (#{kind[:minutes]} allowed). Fixer: #{kind[:fixer]}. " \
            "#{unnamed(kind, subject)}#{seen(kind, waited)}#{move(kind)}"
        end

        # The label of a run the tap ties to no work item, so a run nobody named is seen as one.
        def unnamed(kind, subject)
          @names&.unnamed?(kind, subject) ? "Unnamed run: no works_as or work item recorded. " : ""
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
