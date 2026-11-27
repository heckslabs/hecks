# frozen_string_literal: true

module Hecks
  module Adapters
    # A stand-in for the `Applying` port in a behaviors suite: every target is written, except
    # `lib/unwritable.bluebook`, which cannot be. It touches no file.
    class Applier
      # Raised for the one target the stand-in refuses.
      class Refused < StandardError; end

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil)
        @aggregate = aggregate
      end

      # @return [Hash{Symbol => Object}] the run and target
      # @raise [Refused] when the target is `lib/unwritable.bluebook`
      def write(run:, target:, **)
        raise Refused, "the target cannot be written" if target.fetch(:value) == "lib/unwritable.bluebook"

        { run: run, target: target }
      end
    end
  end
end
