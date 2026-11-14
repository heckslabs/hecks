# frozen_string_literal: true

require "hecks"
require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # The records of a booted registry, read in this process: the board's own registry, or (in
      # {LiveStore}) the one of another checkout. Several readers ask at once from the gather
      # threads, so reads go one at a time, which also settles the registry resolving a repository
      # twice on the first cycle, and an answer is kept for a few seconds so the readers of one
      # refresh share a single load of each aggregate. A reading the domain declares (a query, a
      # read model) is asked for by its name, so its rule stays in the bluebook that declares it.
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

        # @param domain [String] a bluebook of the domain, such as `"Tickets"`
        # @param name [String] an aggregate of it, such as `"Work"`
        # @param query [String] a query the aggregate declares, such as `"Undone"`
        # @return [Array<Hash>] the rows the declared query answers, in its own order
        # @raise [Unavailable] when the registry cannot be read or does not declare the aggregate
        def asked(domain, name, query)
          current = registry
          @lock.synchronize { fresh([domain, name, query]) { answered(current, domain, name, query) } }
        end

        # @param domain [String] a bluebook of the domain, such as `"Tickets"`
        # @param model [String] a read model of it that groups and counts, such as `"WorkByStatus"`
        # @return [Hash{String => Integer}] the count the read model answers for each group
        # @raise [Unavailable] when the registry cannot be read or does not declare the read model
        def tallied(domain, model)
          current = registry
          @lock.synchronize { fresh([domain, model, :tally]) { counted(current, domain, model) } }
        end

        # @param domain [String] a bluebook of the domain, such as `"Tickets"`
        # @param name [String] an aggregate of it, such as `"Work"`
        # @return [Array<Runtime::Event>] every event the aggregate's store holds, oldest first;
        #   none when the store keeps no event log
        # @raise [Unavailable] when the registry cannot be read or does not declare the aggregate
        def events(domain, name)
          current = registry
          @lock.synchronize { fresh([domain, name, :events]) { logged(current, domain, name) } }
        end

        private

        attr_reader :registry

        def logged(current, domain, name)
          aggregate = aggregate_in(current, domain, name)
          raise Unavailable, "#{label} declares no #{domain}.#{name}" unless aggregate

          repository = current.repository(domain, aggregate)
          repository.respond_to?(:events) ? repository.events.to_a : []
        end

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

        def answered(current, domain, name, query)
          aggregate = aggregate_in(current, domain, name)
          raise Unavailable, "#{label} declares no #{domain}.#{name}" unless aggregate

          Runtime::QueryInterpreter.new(current).call(domain, aggregate, query, {})
        end

        def counted(current, domain, model)
          declared = read_model_in(current, domain, model)
          raise Unavailable, "#{label} declares no #{domain}.#{model}" unless declared

          answer = Runtime::ReadModelInterpreter.new(current).call(domain, declared, {})
          groups_of(answer).to_h { |group, count| [group.to_s, count] }
        end

        # The one grouped head of a read model's answer: each group with its count.
        def groups_of(answer) = answer.first.values.first

        def read_model_in(current, domain, model)
          bluebook = current&.bluebook(domain)
          bluebook&.read_models&.find { |candidate| candidate.name.to_s == model }
        end

        def aggregate_in(current, domain, name)
          bluebook = current&.bluebook(domain)
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
        end
      end
    end
  end
end
