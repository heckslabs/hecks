# frozen_string_literal: true

require "time"
require_relative "openings"
require_relative "clearing"
require_relative "key"

module Hecks
  module Adapters
    class StallWatching
      # The computed impediments: one `Sighting` row per pair of open branches that changed the
      # same files against main, naming the files. A `ComputedSignal` row says which tap lines
      # open and close a work item, who fixes the pair and the move; a branch is open while its
      # work item's latest such line is the opening one. The row is never filed: only the
      # impediment view carries it, with how its row says it is cleared ({Clearing}). Its key
      # holds both tips, so a pair is one entry, and one call for help, until either tip moves,
      # and its age runs from the later tip's commit.
      class SharedFiles
        # The reads a row may name.
        READS = %w[shared-files].freeze

        # @param signals [Array<Hash>] the `ComputedSignal` rows: `kind`, `read`, `aggregate`,
        #   `opens`, `closes`, `fixer`, `move`, `cleared_by`
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @param branches [#call] answers the open work keys with `branch:`, `tip:`, `at:` and
        #   `files:` of each that is a local branch ({OpenBranches})
        def initialize(signals, now, branches:)
          @signals = signals
          @now = now
          @branches = branches
        end

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Sighting` row per pair of open branches that share a file
        # @raise [ArgumentError] when a row names a read this adapter does not know
        def rows(lines, run)
          @signals.flat_map do |signal|
            refuse_unknown(signal[:read].to_s)
            open = Openings.new(signal, lines).unclosed.keys
            pairs(open).map { |one, other| row(signal, run, one, other) }
          end
        end

        private

        def refuse_unknown(name)
          return if READS.include?(name)

          raise ArgumentError, "unknown read #{name.inspect}: one of #{READS.join(", ")}"
        end

        # The pairs of open branches, by name, that share a changed file. One open work item
        # makes no pair, so the machine is not read for it.
        def pairs(open)
          return [] if open.size < 2

          by_name(open).combination(2).select { |one, other| one[:files].intersect?(other[:files]) }
        end

        # The open work items that are local branches, in name order, so a pair reads alike
        # at every look.
        def by_name(open) = @branches.call(open).sort_by { |branch| branch[:branch] }

        def row(signal, run, one, other)
          opened = [one[:at], other[:at]].max
          stall = key(signal, one, other)
          { id: run, stall: stall, stall_kind: signal[:kind], subject: "#{one[:branch]}+#{other[:branch]}",
            opened_at: opened, waited: waited(opened), minutes: 0, forgets: 0, fixer: signal[:fixer],
            title: "#{signal[:kind]}: #{one[:branch]} and #{other[:branch]}", detail: detail(signal, one, other),
            filed: "", count: 1, impediment: stall, cleared_by: Clearing.of(signal) }
        end

        # Both branches and both tips, in words a call for help's key may hold ({Key}).
        def key(signal, one, other)
          Key.of(signal[:kind], "#{one[:branch]}.#{other[:branch]}-#{one[:tip]}-#{other[:tip]}")
        end

        def waited(at) = [(@now - Time.iso8601(at).to_i) / 60, 0].max

        def detail(signal, one, other)
          shared = (one[:files] & other[:files]).sort
          "#{one[:branch]} (#{one[:tip]}) and #{other[:branch]} (#{other[:tip]}) both change #{shared.join(", ")} " \
            "against main. Fixer: #{signal[:fixer]}. Move: #{signal[:move]} Never stop or kill a session."
        end
      end
    end
  end
end
