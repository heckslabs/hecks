# frozen_string_literal: true

require "json"
require "hecks/catcher/adapters/spool_cursor"

module Hecks
  module Adapters
    # The `Spool` port's adapter for `Drain`: answers the `Read` ask from the spool file the Claude
    # Code hook appends to, one JSON object per line, after the cursor `SpoolCursorFile` moves.
    #
    # It only reads, and never writes the spool or the cursor. It decides nothing about what a line
    # means: the bluebook keeps each call as a sitting's record.
    class SpoolFile
      # The fields a call takes, each read from the spool line under the same name except the
      # call's id, which is the line's `observation_id`.
      FIELDS = %i[source tool subject succeeded observed_in observed_at].freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the spool file (default `SpoolCursor::DEFAULT_PATH`)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @cursor = SpoolCursor.new(settings)
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
        done = @cursor.position
        complete = spooled
        calls = complete.drop(done).filter_map { |line| call(line) }
        { lines: calls, through: { value: [complete.size, done].max } }
      end

      private

      def spooled
        return [] unless File.file?(@cursor.spool)

        File.foreach(@cursor.spool).select { |line| line.end_with?("\n") }
      end

      def call(line)
        return if line.strip.empty?

        parsed = JSON.parse(line, symbolize_names: true)
        return unless parsed.is_a?(Hash) && [:observation_id, *FIELDS].all? { |f| parsed.key?(f) }

        { call_id: parsed[:observation_id], **parsed.slice(*FIELDS) }
      rescue JSON::ParserError
        nil
      end
    end
  end
end
