# frozen_string_literal: true

module Hecks
  module Adapters
    # A stand-in for the `Previewing` port in a behaviors suite: every target diffs to `cd34` and
    # passes its checks, except `lib/missing.bluebook`, which cannot be read, and
    # `lib/broken.bluebook`, whose checks fail. It touches no file.
    class Previewer
      # Raised for the two targets the stand-in refuses.
      class Refused < StandardError; end

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil)
        @aggregate = aggregate
      end

      # @return [Hash{Symbol => Object}] the run and target with the fixed digest
      # @raise [Refused] when the target is `lib/missing.bluebook`
      def diff(run:, target:, **)
        refuse(target, "lib/missing.bluebook", "the target cannot be read")
        { run: run, target: target, diff: { value: "cd34" } }
      end

      # @return [Hash{Symbol => Object}] the run with `outcome:` `passed`
      # @raise [Refused] when the target is `lib/broken.bluebook`
      def check(run:, target:, **)
        refuse(target, "lib/broken.bluebook", "the target does not load with the edits")
        { run: run, outcome: { value: "passed" } }
      end

      private

      def refuse(target, named, reason)
        raise Refused, reason if target.fetch(:value) == named
      end
    end
  end
end
