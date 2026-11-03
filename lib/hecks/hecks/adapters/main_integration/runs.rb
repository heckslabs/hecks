# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The open and finished runs of the MainIntegration saga, read from the booted registry:
      # each landed commit, the stage its run is in and the checkout it landed in. Writes nothing.
      class Runs
        # The saga whose instances are read.
        SAGA = "MainIntegration"

        # The stages in which a run is being pushed or watched; only one run may be in them.
        IN_FLIGHT = %w[boarding pushed ci_running].freeze

        # One run: the landed commit it is keyed by, its stage, and the checkout it landed in.
        Run = Struct.new(:landed, :state, :checkout) do
          # @return [String] the commit's first ten characters, for a report
          def short = landed[0, 10]
        end

        # @param registry [Runtime::Registry] the booted registry whose saga instances are read
        def initialize(registry)
          @registry = registry
        end

        # @return [Array<Run>] every run the saga remembers, in the order they started
        def all
          instances.map { |landed, instance| Run.new(landed.to_s, instance[:state].to_s, checkout_of(instance)) }
        end

        # @param landed [String] the landed commit
        # @return [Run, nil] the run keyed by it
        def find(landed) = all.find { |run| run.landed == landed.to_s }

        # @param landed [String] the run to leave out
        # @return [Array<Run>] the other runs that are being pushed or watched
        def in_flight(except: nil) = all.select { |run| run.landed != except.to_s && IN_FLIGHT.include?(run.state) }

        private

        def instances = @registry.saga_instances[SAGA] || {}

        def checkout_of(instance)
          held = (instance[:memory] || {})[:checkout]
          held = held[:value] if held.is_a?(Hash)
          held.respond_to?(:value) ? held.value.to_s : held.to_s
        end
      end
    end
  end
end
