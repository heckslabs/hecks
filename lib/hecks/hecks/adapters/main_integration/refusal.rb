# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The text a failed verification refuses with. Its first line names every failed check and,
      # for the first one, the spec file and example it printed and the log kept for it; a block
      # for each failed check follows with the last lines it printed and its log.
      class Refusal
        # One failed check: its name, the last lines it printed, the log kept and what the
        # output named (`FailureLog.finding`).
        Failure = Struct.new(:name, :tail, :log, :finding)

        # @param landed [String] the commit that failed verification
        # @param failures [Array<Failure>] the failed checks, in the order they ran
        # @param tail [Integer] how many lines each block holds
        def initialize(landed, failures, tail)
          @landed = landed
          @failures = failures
          @tail = tail
        end

        # @return [String] the refusal
        def to_s = [headline, *@failures.map { |failure| block(failure) }].join("\n")

        private

        def headline
          names = @failures.map(&:name).join(", ")
          "#{@landed[0, 10]} failed verification: #{names}#{detail(@failures.first)}"
        end

        def detail(failure)
          found = failure.finding
          parts = [("spec #{found[:spec]}" if found[:spec]),
                   ("first failing example #{found[:example]}" if found[:example]),
                   ("log #{failure.log}" if failure.log)]
          parts.compact.map { |part| "; #{part}" }.join
        end

        def block(failure)
          where = " (log #{failure.log})" if failure.log
          "--- #{failure.name}, the last #{@tail} lines#{where}:\n#{failure.tail}"
        end
      end
    end
  end
end
