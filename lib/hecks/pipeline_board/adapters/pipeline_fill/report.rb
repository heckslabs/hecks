# frozen_string_literal: true

module Hecks
  module Adapters
    class PipelineFill
      # The text of one fill report, read into the fields the board shows. The header states the
      # load, the started count and the cap: `started 4 of cap 6`, or, while admission goes by
      # headroom, `started 4; admission by headroom ...` with the cap in the headroom clause.
      module Report
        # A report's first line, where its header is.
        FIRST_LINE = /\A[^\n]*/
        HEADER = /\Aload ([\d.]+) \(limit ([\d.]+), (\d+) cpus\); started (\d+)(?: of cap (\d+))?;/
        # The cap as the headroom clause states it, read when the started clause states none.
        CAP = /; headroom (?:\d+|unread) of cap (\d+)/
        # The clause `headroom 2 of cap 7 (1.6 load per session)`; `headroom unread` states neither.
        ROOM = /; headroom (\d+) of cap \d+ \(([\d.]+) load per session\);/
        # The time a report's header ends with.
        RAN_AT = /; at (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\z/
        WOULD = /\Awould start (\S+): (.*)\z/
        LAUNCHED = /\Astarted (\S+)(?: \(then refused: (.*)\))?\z/
        YIELDED = /\Ayielded (\S+): (.*)\z/
        SKIPPED = /\A(\S+) skipped: (.*)\z/

        module_function

        # @param text [String] a report
        # @return [Boolean] whether its first line is a fill's header
        def readable?(text) = HEADER.match?(first_line(text))

        # @param text [String] a report
        # @return [String, nil] the time its header says the fill ran, nil when it states none
        def ran_at(text) = RAN_AT.match(first_line(text))&.then { |stated| stated[1] }

        # @param text [String] a report
        # @return [Hash, nil] its fields (see {PipelineFill#preview}), nil when it has no header
        def parse(text)
          lines = text.lines.map(&:strip)
          counts = HEADER.match(first_line(text)) or return
          header(counts).merge(would_start: pairs(lines, WOULD, :slug, :title), launched: launched(lines),
                               skipped: pairs(lines, SKIPPED, :slug, :reason) + pairs(lines, YIELDED, :slug, :reason))
        end

        def first_line(text) = text.to_s[FIRST_LINE].strip

        def header(counts)
          line = counts.string
          { load: counts[1].to_f, limit: counts[2].to_f, cap: cap(counts), started: counts[4].to_i,
            at: ran_at(line) }.merge(room(line))
        end

        # @return [Integer, nil] the cap the started clause states, else the headroom clause's
        def cap(counts) = (counts[5] || CAP.match(counts.string)&.then { |stated| stated[1] })&.to_i

        # @return [Hash] `headroom` and `per_session` as the report states them, else nil
        def room(line)
          found = ROOM.match(line)
          { headroom: found&.then { |stated| stated[1].to_i }, per_session: found&.then { |stated| stated[2].to_f } }
        end

        def launched(lines)
          lines.filter_map { |line| (found = LAUNCHED.match(line)) && { slug: found[1] } }
        end

        def pairs(lines, pattern, first, second)
          lines.filter_map { |line| (found = pattern.match(line)) && { first => found[1], second => found[2] } }
        end
      end
    end
  end
end
