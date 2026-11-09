# frozen_string_literal: true

require "json"
require_relative "../../../boot_notices"

module Hecks
  module Adapters
    class Dispatching
      # What one launcher step's command did, read from the record it printed rather than from its
      # exit status alone: a command can reach its own state while a reaction that follows it is
      # refused, and its stderr can open with warnings that have nothing to do with it.
      class StepOutcome
        # The JSON object a command prints after any log lines.
        JSON_OBJECT = /\{.*\}/m

        # The most of a reason a report line quotes.
        LIMIT = 300

        # A run of whitespace, newlines included, which a reason folds to one space so it stays on
        # its report line.
        BLANKS = /\s+/

        # @param result [Shell::Result] the command's output and status
        # @param reaches [String, nil] the status the command's record holds when it did its part,
        #   or nil when only a clean exit counts
        # @param decided_by_status [Boolean] whether the record's status alone says if the command
        #   did its part, for a record that keeps a refusal from an earlier command (a run keeps the
        #   reason it was last declined or left unretired after it is retired)
        def initialize(result, reaches: nil, decided_by_status: false)
          @result = result
          @reaches = reaches
          @decided_by_status = decided_by_status && !reaches.nil?
        end

        # @return [Boolean] whether the command did its part: a clean exit without a refusal, or a
        #   record that reached the status asked for though a later reaction was refused
        def ok?
          return status == @reaches if @decided_by_status
          return false if refusal

          @result.ok? || (!@reaches.nil? && status == @reaches)
        end

        # @return [String] what a later reaction refused, empty when nothing was refused
        def note = ok? && !@result.ok? ? reason : ""

        # @return [String] why the command failed: its record's refusal, else its stderr without the
        #   boot notices (`BootNotices`), else its stdout, else the notices, on one line. A refusal
        #   that carries notices after their divider gives only its own words.
        def reason = told.gsub(BLANKS, " ")[0, LIMIT]

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

        # The cause as one string: the refusal's own words, else the command's own stderr lines,
        # else its stdout, else whatever notices it printed.
        def told
          return BootNotices.cause(refusal) if refusal

          own = [BootNotices.split(@result.err).first, @result.out.strip].find { |text| !text.empty? }
          own || BootNotices.cause(@result.err)
        end
      end
    end
  end
end
