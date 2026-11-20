# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What {SignalboxDoor} asks of Signalbox's `Breaker`: the protection order its Order rows
      # declare, and whether one breaker trips, by dry run. A breaker is installed once per level
      # and rating, so a long-lived process keeps one record for each rating it has met.
      module BreakerDoor
        # The head of a refused trip's message, before the given that refused it.
        TRIP_REFUSED = /\ATrip refused — /

        # @return [Array<Hash>] the Order rows, each `level:`, `rank:` and `holds:`, smallest first
        def order = order_rows.map { |row| row.transform_keys(&:to_sym) }.sort_by { |row| row[:rank].to_i }

        # @param level [String] the breaker's level
        # @param rating [Integer] what it is rated at
        # @param load [Integer] its load now
        # @param smaller_ready [Integer] the smaller breakers that tripped and can act
        # @return [String, nil] the given that keeps it closed, nil when it trips
        def trip_refusal(level, rating:, load:, smaller_ready:)
          key = installed(level, rating)
          runtime.dry_run?("Signalbox::Breaker.Trip", breaker: key, load: { value: load },
                                                      smaller_ready: { value: smaller_ready })
          nil
        rescue StandardError => e
          e.message.sub(TRIP_REFUSED, "")
        end

        private

        def order_rows
          aggregate = runtime.bluebook("Signalbox").aggregates.find { |held| held.hecks_name == "Breaker" }
          Array(aggregate&.value_objects&.find { |object| object.hecks_name == "Order" }&.members)
        end

        def installed(level, rating)
          key = "protection-#{level}-#{rating}"
          @installed ||= Set.new
          return key if @installed.include?(key)

          runtime.dispatch("Signalbox::Breaker.Install",
                           with: { breaker: { value: key }, level: { value: level }, rating: { value: rating } })
          @installed << key
          key
        end
      end
    end
  end
end
