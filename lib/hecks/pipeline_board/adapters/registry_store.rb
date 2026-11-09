# frozen_string_literal: true

require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # The records of a booted registry, read in this process: the board's own registry, or (in
      # {LiveStore}) the one of another checkout. Several readers ask at once from the gather
      # threads, so reads go one at a time, which also settles the registry resolving a repository
      # twice on the first cycle, and an answer is kept for a few seconds so the readers of one
      # refresh share a single load of each aggregate.
      class RegistryStore
        # Seconds an aggregate's records are kept.
        CACHE_SECONDS = 5
        # The time in seconds, from the monotonic clock.
        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        # @param registry [Runtime::Registry, nil] the booted registry that is read
        # @param clock [#call] the time in seconds
        # @param cache_seconds [Numeric] how long an aggregate's records are kept
        def initialize(registry: nil, clock: MONOTONIC, cache_seconds: CACHE_SECONDS)
          @registry = registry
          @clock = clock
          @cache_seconds = cache_seconds
          @lock = Mutex.new
          @kept = {}
        end

        # @param domain [String] a bluebook of the domain, such as `"Hecks"`
        # @param name [String] an aggregate of it, such as `"AgentRun"`
        # @return [Array<Object>] every record of the aggregate
        # @raise [Unavailable] when the registry cannot be read or does not declare the aggregate
        def records(domain, name)
          current = registry
          @lock.synchronize { fresh([domain, name]) { read(current, domain, name) } }
        end

        private

        attr_reader :registry

        # What the store is called in a refusal.
        def label = "the board's registry"

        def fresh(key)
          kept = @kept[key]
          return kept.last if kept && @clock.call - kept.first < @cache_seconds

          value = yield
          @kept[key] = [@clock.call, value]
          value
        end

        def read(current, domain, name)
          aggregate = aggregate_in(current, domain, name)
          raise Unavailable, "#{label} declares no #{domain}.#{name}" unless aggregate

          current.repository(domain, aggregate).all.to_a
        end

        def aggregate_in(current, domain, name)
          bluebook = current&.bluebook(domain)
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
        end
      end
    end
  end
end
