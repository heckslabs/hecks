# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class Dispatching
      # What one launcher step's command did, read from the record it printed rather than from its
      # exit status alone: a command can reach its own state while a reaction that follows it is
      # refused, and its stderr can open with warnings that have nothing to do with it.
      class StepOutcome
        # The JSON object a command prints after any log lines.
        JSON_OBJECT = /\{.*\}/m

        # Lines a command writes to stderr that are never the reason it failed: the runtime's own
        # boot warnings, such as a process manager whose adapter has no `save_saga`, and the
        # worktree's note that it stores in Memory. This is a filter on known noise.
        NOISE = [/\A\[hecks\] /, /\Ahecks: this worktree lacks /].freeze

        # The most of a reason a report line quotes.
        LIMIT = 300

        # A run of whitespace, newlines included, which a reason folds to one space so it stays on
        # its report line.
        BLANKS = /\s+/

        # @param result [Shell::Result] the command's output and status
        # @param reaches [String, nil] the status the command's record holds when it did its part,
        #   or nil when only a clean exit counts
        def initialize(result, reaches: nil)
          @result = result
          @reaches = reaches
        end

        # @return [Boolean] whether the command did its part: a clean exit without a refusal, or a
        #   record that reached the status asked for though a later reaction was refused
        def ok?
          return false if refusal

          @result.ok? || (!@reaches.nil? && status == @reaches)
        end

        # @return [String] what a later reaction refused, empty when nothing was refused
        def note = ok? && !@result.ok? ? reason : ""

        # @return [String] why the command failed: its record's refusal, else its stderr without the
        #   known noise, else its stdout, on one line
        def reason = (refusal || [quiet_err, @result.out.strip].find { |text| !text.empty? }).to_s.gsub(BLANKS, " ")[0, LIMIT]

        # @return [Hash, nil] the record the command printed, nil when it printed none
        def printed
          text = @result.out[JSON_OBJECT]
          text && JSON.parse(text)
        rescue JSON::ParserError
          nil
        end

        private

        def status = printed&.dig("state", "status")

        def refusal
          answer = printed || {}
          text(answer["refusal"]) || text(answer.dig("state", "refusal"))
        end

        # The text itself when it says something, else nil.
        def text(value) = value.is_a?(String) && !value.strip.empty? ? value.strip : nil

        # The command's stderr without the lines known to be noise.
        def quiet_err = said_lines.join.strip

        # The command's stderr lines that are not noise.
        def said_lines = @result.err.lines.reject { |line| noise?(line) }

        def noise?(line) = NOISE.any? { |noise| noise.match?(line) }
      end
    end
  end
end
