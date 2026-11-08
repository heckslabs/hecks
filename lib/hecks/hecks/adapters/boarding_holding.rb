# frozen_string_literal: true

require_relative "boarding_hold_marking"

module Hecks
  module Adapters
    # The `Holding` port's adapter for `BoardingHold`: writes and reads the marker that holds local
    # main for a boarding. It touches no ledger and moves nothing in git; it only reads main's
    # commit to name the hold.
    class BoardingHolding
      include BoardingHoldMarking

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `minutes:` the window and `clock:`, for a spec
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] where the world's `boarding_hold` setting is read
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @git = Git.new
        @settings = settings
        @registry = registry
      end

      # Holds main for the commit it names now.
      #
      # @param held [Hash] the `BoardingHold` record: `checkout`, optional `owner` and `reason`
      # @return [Hash{Symbol => Hash}] `output:` what was held
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository or has no main
      def mark(**held)
        marker = marker_of(held)
        marker.hold!(boarding: read(held, "rev-parse", "--verify", "main"), owner: owner(held),
                     reason: plain(held[:reason]) || "boarding")
        { output: { value: marker.status } }
      end

      # @param held [Hash] `checkout`
      # @return [Hash{Symbol => String}] `text:` the hold's commit, owner, reason and age
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def status(**held) = { text: marker_of(held).status }

      private

      def owner(held) = plain(held[:owner]) || ENV["HECKS_HOLD_OWNER"] || "unnamed"
    end
  end
end
