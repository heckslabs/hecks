# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # The one line that closes a trace.
          module Summary
            OUTCOMES = %w[delivered refused pending claimed failed].freeze

            module_function

            # @param read [Array<Hash>] the stores as read
            # @param events [Array<Hash>] the traced event rows
            # @param never [Array<Hash>, nil] the policies whose event never occurred, or nil
            # @return [String] the line
            def line(read, events, never)
              "#{events.size} events in #{read.size} store(s); outcomes: #{outcomes(events)}; " \
                "#{events.count { |row| row[:subscribers].empty? }} without a subscriber; #{unheard(never)}"
            end

            # @return [String] the count of each outcome found, in a fixed order
            def outcomes(events)
              counts = events.flat_map { |row| row[:subscribers] }.map { |sub| sub[:outcome] }.tally
              parts = (OUTCOMES + ["no record"]).filter_map { |name| "#{counts[name]} #{name}" if counts[name] }
              parts.empty? ? "none" : parts.join(", ")
            end

            # @return [String] how many policies never saw their event, in the stores read
            def unheard(never)
              never ? "#{never.size} policies whose event never occurred (in the stores read)" : "never-occurred unknown"
            end
          end
        end
      end
    end
  end
end
