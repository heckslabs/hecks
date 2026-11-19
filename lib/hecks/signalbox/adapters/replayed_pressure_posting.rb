# frozen_string_literal: true

module Hecks
  module Adapters
    # A `PressurePosting` that keeps each post in memory instead of writing the machine's signal
    # file, for `signalbox.behaviors` and the specs: a behaviors boot must leave the machine as it
    # was.
    class ReplayedPressurePosting
      class << self
        # @return [Array<Hash>] every Pressure record posted in this process, oldest first
        def posted = (@posted ||= [])
      end

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil); end

      # @param held [Hash] the settled `Pressure` record
      # @return [Hash{Symbol => Hash}] `pressure:` the key posted
      def post(**held)
        self.class.posted << held
        { pressure: held[:pressure].is_a?(Hash) ? held[:pressure] : { value: held[:pressure] } }
      end
    end
  end
end
