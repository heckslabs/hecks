module Hecks
  module Adapters
    module Driving
      module Clock
        # What keeps one firing from running twice across processes (ADR 0184, decided 2).
        module FiringLock
          # Memory keeps its state inside one process, so no other process shares the domain and
          # nothing needs taking: every firing proceeds.
          class InProcess
            # @param _name [String] the clock's name
            # @param _due [Integer] the firing's due instant
            # @return [Boolean] always true
            def acquired?(_name, _due) = true
          end

          # A Postgres advisory lock per clock name and due instant, taken for each firing on a
          # connection of its own. It is held until the next firing takes its own, so a replica
          # that wakes for the same tick a moment later finds it taken and does not fire.
          class PostgresAdvisory
            # @param connection [#exec_params] a connection that holds no other session's locks
            def initialize(connection)
              @connection = connection
              @held = nil
            end

            # @param name [String] the clock's name
            # @param due [Integer] the firing's due instant
            # @return [Boolean] whether this process took the firing
            def acquired?(name, due)
              release
              key = "hecks_clock:#{name}:#{due}"
              taken = @connection.exec_params("SELECT pg_try_advisory_lock(hashtext($1)) AS taken", [key])
              @held = key if taken[0]["taken"] == "t"
              !@held.nil?
            end

            private

            def release
              return unless @held

              @connection.exec_params("SELECT pg_advisory_unlock(hashtext($1))", [@held])
              @held = nil
            end
          end

          # Adapters whose stores live in a shared Postgres database.
          POSTGRES = %w[Postgres].freeze

          module_function

          # The lock for a clock's domain: an advisory lock when the dispatched command's aggregate
          # is kept in Postgres, else none beyond the one process.
          #
          # @param registry [Runtime::Registry] the booted registry
          # @param clock [Bluebook::Clock] the clock
          # @param domain [String] the domain the clock is declared on
          # @return [InProcess, PostgresAdvisory] the lock
          def for(registry, clock, domain)
            adapter, settings = persistence(registry, clock, domain)
            return InProcess.new unless POSTGRES.include?(adapter)

            require "hecks/pg_options"
            PostgresAdvisory.new(PG.connect(settings[:database].to_s))
          end

          # @return [Array(String, Hash)] the adapter keeping the aggregate, and its settings
          def persistence(registry, clock, domain)
            aggregate = registry.bluebook(domain)&.aggregate(clock.aggregate_name)
            return ["Memory", {}] unless aggregate

            adapter = Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate).adapter.to_s
            [adapter, registry.binding_settings(domain, Ports::Persistence::VERB, adapter).transform_keys(&:to_sym)]
          end
        end
      end
    end
  end
end
