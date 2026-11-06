# frozen_string_literal: true

module Hecks
  module Adapters
    class IterationWatch
      # The attempts rule: the same step has failed `attempts` times in a row, for one reason.
      #
      # A failure is an event of FAILURES; a step that went through (PASSES) ends the run. The kind
      # of a failure is its step and the class of its reason, so a different reason starts the
      # count again.
      class Attempts
        # The failure events: the step each one is a failure of, and the noun a line counts it by.
        FAILURES = {
          "LandingRefused" => ["landing", "refused landings"], "MergeRefused" => ["landing", "refused landings"],
          "TrainRefused" => ["train", "refused trains"], "ConveneRefused" => ["train", "refused trains"],
          "PushRehearsalFailed" => ["rehearsal", "red rehearsals"], "PushRehearsalDeclined" => ["rehearsal", "refused rehearsals"],
          "RehearsalFailed" => ["rehearsal", "red rehearsals"], "RehearsalRefused" => ["rehearsal", "refused rehearsals"],
          "MintRefused" => ["mint", "refused mints"], "GateRefused" => ["gate", "refused gates"]
        }.freeze

        # The events that say a step went through.
        PASSES = %w[BranchLanded PushRehearsalPassed RehearsalPassed].freeze

        # The payload fields a reason is read from, first found first.
        REASONS = %w[refusal report reason rehearsal_verdict].freeze

        # The reason's class: what comes before its first colon, semicolon or stop, without numbers.
        CLASS = /\A[^:;.\n]*/

        # @param limit [Integer] the failures in a row that make the rule trip
        def initialize(limit)
          @limit = limit
        end

        # @param events [Array<Log::Event>] one row's events, oldest first
        # @return [String, nil] the line that says the rule tripped, nil when it did not
        def call(events)
          run = trailing(events.select { |event| FAILURES.key?(event.name) || PASSES.include?(event.name) })
          return unless run.size >= @limit && FAILURES.key?(run.last.name)

          "#{run.size} #{FAILURES.fetch(run.last.name).last} in a row, same reason: #{reason_class(run.last)}"
        end

        private

        def trailing(steps)
          return [] if steps.empty?

          steps.reverse.take_while { |event| kind(event) == kind(steps.last) }
        end

        def kind(event) = [FAILURES.fetch(event.name, [nil]).first, reason_class(event)]

        def reason_class(event)
          return "passed" if PASSES.include?(event.name)

          said = REASONS.filter_map { |field| plain(event.payload[field]) }.first.to_s
          said[CLASS].to_s.downcase.gsub(/\d+/, "N").strip[0, 60]
        end

        def plain(field) = field.is_a?(Hash) ? field["value"] : field
      end
    end
  end
end
