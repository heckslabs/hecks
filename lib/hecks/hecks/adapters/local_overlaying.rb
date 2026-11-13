# frozen_string_literal: true

require_relative "console_capture"
require_relative "main_integration"
require_relative "main_integration/local_overlay"

module Hecks
  module Adapters
    # The `Overlaying` port's adapter for `LocalOverlay.Write`, through its `Lay` ask: writes a
    # checkout's gitignored overlay from the `KeptAggregate` rows of the aggregate it serves. It
    # touches one file, no ledger and no git state.
    class LocalOverlaying
      # @param aggregate [Bluebook::Aggregate, nil] `LocalOverlay`, whose kept rows are written
      # @param registry [Runtime::Registry, nil] unused
      def initialize(aggregate: nil, registry: nil)
        @rows = MainIntegration::KeptRows.of(aggregate)
      end

      # @param held [Hash] the `LocalOverlay` record: `root` and `copy`
      # @return [Hash{Symbol => Hash}] `output:` the path written, or that the overlay was current
      # @raise [ConsoleCapture::Failure] naming an unknown copy, a checkout with no Hecks domain, or
      #   a copy that keeps no row
      def lay(**held)
        root = File.expand_path(plain(held[:root]).to_s)
        overlay = MainIntegration::LocalOverlay.new(root, @rows, copy_of(held))
        refuse!("#{root} holds no lib/hecks/hecks, so it is not a hecks checkout") unless hecks_checkout?(overlay)
        written = overlay.write
        { output: { value: written ? "wrote #{written}" : "#{overlay.path} is current" } }
      rescue MainIntegration::LocalOverlay::Empty => e
        refuse!(e.message)
      end

      private

      def hecks_checkout?(overlay) = File.directory?(File.dirname(overlay.path))

      def copy_of(held)
        copy = plain(held[:copy]).to_s
        return copy if MainIntegration::KeptRows::COPIES.include?(copy)

        refuse!("copy #{copy.inspect} is not one of #{MainIntegration::KeptRows::COPIES.join(", ")}")
      end

      def refuse!(message) = raise(ConsoleCapture::Failure, message)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
