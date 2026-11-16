# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Reduces the Ruby `[BUG]` report a crashed board leaves in its log to one line: where it
      # died, what kind of fault and which interpreter. A pure function from text to a string, with
      # no decision in it; whether to start the board again is the watchdog's. It serves the board
      # watchdog (`~/.claude/hecks-dev/board-watch.sh`), which has no other way to name a cause.
      module CrashDigest
        # The first line of a report: the place, then the fault.
        REPORT = /^(?<place>\S+): \[BUG\] (?<fault>[^\n]*)\n(?<ruby>ruby [^\n]*)/

        # The checkout prefix of a path, up to `lib/`.
        CHECKOUT_PREFIX = %r{\A.*/lib/}
        # The interpreter name and version at the start of the version line.
        INTERPRETER = /\Aruby \S+/

        # @param log [String] the tail of a board log
        # @return [String, nil] `fault at place (interpreter)` for the newest report; nil when the
        #   log holds none
        def self.line(log)
          report = log.to_enum(:scan, REPORT).map { Regexp.last_match }.last
          return nil unless report

          place = report[:place].sub(CHECKOUT_PREFIX, "lib/")
          "#{report[:fault]} at #{place} (#{report[:ruby][INTERPRETER]})"
        end
      end
    end
  end
end
