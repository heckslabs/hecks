# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Adapters
    # The `Spool` port's adapter for `Drain`: answers the `Read` ask from the spool file the Claude
    # Code hook appends to, one JSON object per line, and the `Acknowledge` ask by moving a cursor
    # kept in a sidecar file beside it.
    #
    # It never writes the spool. The cursor is the number of spool lines already kept, counting
    # blank and unreadable ones, and it only moves forward. It decides nothing about what a line
    # means: the bluebook keeps each call as a sitting's record.
    class SpoolFile
      # Where the hook appends, when the settings name no other path.
      DEFAULT_PATH = "~/.claude/hecks-dev/observations.spool"

      # The suffix of the sidecar that holds the cursor, beside the spool.
      CURSOR_SUFFIX = ".cursor"

      # The fields a call takes, each read from the spool line under the same name except the
      # call's id, which is the line's `observation_id`.
      FIELDS = %i[source tool subject succeeded observed_in observed_at].freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the spool file (default {DEFAULT_PATH})
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @path = File.expand_path(settings[:path] || DEFAULT_PATH)
        @cursor = "#{@path}#{CURSOR_SUFFIX}"
      end

      # Reads the lines the spool holds after the cursor. A blank or unreadable line is not
      # answered but is counted, so the cursor moves past it. A final line the hook has not yet
      # ended with a newline is left for the next read.
      #
      # @param _held [Hash] the `Drain` record: `run`; unused
      # @return [Hash{Symbol => Object}] `lines:` one Hash per call, with `call_id` and the
      #   fields in {FIELDS}; `through:` the number of spool lines consumed so far
      # @raise [SystemCallError] when the spool or the cursor exists and cannot be read
      def read(**_held)
        done = cursor
        complete = spooled
        calls = complete.drop(done).filter_map { |line| call(line) }
        { lines: calls, through: { value: [complete.size, done].max } }
      end

      # Moves the cursor to `through`, never backward. The spool is not touched.
      #
      # @param held [Hash] `run:` the drain's run, `through:` the count to move the cursor to
      # @return [Hash] empty
      # @raise [SystemCallError] when the cursor cannot be written
      def acknowledge(**held)
        target = plain(held[:through]).to_i
        store(target) if target > cursor
        {}
      end

      private

      def spooled
        return [] unless File.file?(@path)

        File.foreach(@path).select { |line| line.end_with?("\n") }
      end

      def call(line)
        return if line.strip.empty?

        parsed = JSON.parse(line, symbolize_names: true)
        return unless parsed.is_a?(Hash) && [:observation_id, *FIELDS].all? { |f| parsed.key?(f) }

        { call_id: parsed[:observation_id], **parsed.slice(*FIELDS) }
      rescue JSON::ParserError
        nil
      end

      def cursor
        return 0 unless File.file?(@cursor)

        File.read(@cursor).to_i
      end

      def store(count)
        FileUtils.mkdir_p(File.dirname(@cursor))
        temporary = "#{@cursor}.#{Process.pid}.tmp"
        File.write(temporary, "#{count}\n")
        File.rename(temporary, @cursor)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
