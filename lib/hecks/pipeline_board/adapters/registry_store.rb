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
        # How many times its own load time a slow aggregate's records are kept, so a load that
        # takes longer than the cache window is not started again the moment it finishes.
        HOLD_TIMES = 10
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

        # The checkpoints a process manager keeps, asked of the store the registry resolves for it
        # and not of the registry's own memory: a read-only boot restores no saga, and a stored
        # checkpoint moves after the boot.
        #
        # @param domain [String] the bluebook that declares the process manager, such as `"Hecks"`
        # @param process_manager [String] its name, such as `"MainIntegration"`
        # @return [Hash{String => String}] each instance's correlation and the state stored for
        #   it; none when the store keeps no checkpoint
        # @raise [Unavailable] when the registry cannot be read
        def sagas(domain, process_manager)
          current = registry
          @lock.synchronize { fresh([domain, process_manager, :sagas]) { checkpoints(current, domain, process_manager) } }
        end

        private

        attr_reader :registry

        def checkpoints(current, domain, process_manager)
          raise Unavailable, "#{label} resolves no saga store" unless current.respond_to?(:saga_persistence)

          kept_sagas(current.saga_persistence(domain, process_manager)).each_with_object({}) do |saga, found|
            name, correlation, state = saga
            found[correlation.to_s] = state.to_s if name.to_s == process_manager
          end
        end

        # Every checkpoint a saga store holds; none for the store of a domain that keeps none.
        def kept_sagas(store) = store.each_saga.to_a

        def logged(current, domain, name)
          aggregate = aggregate_in(current, domain, name)
          raise Unavailable, "#{label} declares no #{domain}.#{name}" unless aggregate

          repository = current.repository(domain, aggregate)
          repository.respond_to?(:events) ? repository.events.to_a : []
        end

        # What the store is called in a refusal.
        def label = "the board's registry"

        # The kept value of the key while it is current, else the block's value, kept for the longer
        # of the cache window and {HOLD_TIMES} its load time. A load that raises is kept for none.
        def fresh(key)
          at, value, took = @kept[key]
          return value if at && @clock.call - at < [@cache_seconds, took * HOLD_TIMES].max

          started = @clock.call
          value = yield
          @kept[key] = [@clock.call, value, @clock.call - started]
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
