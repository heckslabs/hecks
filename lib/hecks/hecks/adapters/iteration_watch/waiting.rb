# frozen_string_literal: true

module Hecks
  module Adapters
    class IterationWatch
      # The waiting rule: the minutes a row spent waiting, summed, passed `wait_minutes`.
      #
      # A landing records `waited_seconds`. A report from before that was recorded, and a refusal
      # ("queue busy: ... waited 15m 0s behind ..."), say it in words, which are read the same way.
      # The lock wait of a landing is part of that wait; a wait in a background session is not
      # recorded anywhere, so it is not counted.
      class Waiting
        # How the landing report words a wait: `waited 45s` or `waited 12m 3s`.
        WORDS = /waited (?:(\d+)m (\d+)s|(\d+)s)/

        # @param limit [Numeric] the minutes that make the rule trip
        def initialize(limit)
          @limit = limit
        end

        # @param events [Array<Log::Event>] one row's events
        # @return [String, nil] the line that says the rule tripped, nil when it did not
        def call(events)
          minutes = events.sum { |event| seconds(event) } / 60
          "waited #{minutes.round} min of #{@limit}" if minutes > @limit
        end

        private

        def seconds(event)
          recorded = event.payload["waited_seconds"]
          recorded = recorded["value"] if recorded.is_a?(Hash)
          return recorded.to_i unless recorded.nil?

          said(event.text)
        end

        def said(text)
          found = text.match(WORDS)
          return 0 unless found

          found[3] ? found[3].to_i : (found[1].to_i * 60) + found[2].to_i
        end
      end
    end
  end
end
