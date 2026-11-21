# frozen_string_literal: true

module Hecks
  module Adapters
    class LandingPaceReading
      # The text of a throughput: the branches landed in a window, one per `BranchLanded`, and the
      # ones shipped, whose landed commit `origin/main` already contains.
      class Throughput
        # @param landed [Array<Pairing::Landed>] the landings in the window
        # @param hours [Integer] the length of the window measured
        # @param shipped [#call] answers whether a commit sha has reached origin
        def initialize(landed, hours:, shipped:)
          @landed = landed
          @hours = hours
          @shipped = shipped
        end

        # @return [String] the landed and shipped counts of the window, then the unshipped branches
        def text
          waiting = @landed.reject { |landing| reached?(landing) }
          ["last #{@hours} hours", "landed: #{@landed.size}", "shipped: #{@landed.size - waiting.size}",
           "waiting to ship: #{waiting.size}", *waiting.map { |landing| "  #{landing.branch}" }].join("\n")
        end

        private

        def reached?(landing) = landing.sha && @shipped.call(landing.sha)
      end
    end
  end
end
