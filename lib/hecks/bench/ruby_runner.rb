require_relative "run"

module Hecks
  module Bench
    # Measures the Ruby runtime, in-process, on one persistence adapter.
    #
    # The domain is booted from a throwaway copy through `Fuzzing::IsolatedBoot`, so a
    # run always starts from an empty store and never touches the example's own data.
    # That is the same isolation `bin/fuzz --adapter` uses. Both Postgres adapters write
    # to a uniquely named schema in the `hecks_bench` database, which is dropped after the
    # run, so a concurrent `bin/fuzz` and its shared `hecks_fuzz` schema are never touched.
    #
    # Only `dispatch_flat` is inside the timer. Boot, setup commands and warmup are not.
    module RubyRunner
      # The adapters this runner can bind, as `IsolatedBoot` names them.
      ADAPTERS = %i[memory sqlite postgres postgres_era].freeze

      # The adapters that need a server and a scratch schema.
      POSTGRES_ADAPTERS = %i[postgres postgres_era].freeze

      # The scratch database both Postgres adapters run in.
      DATABASE = "hecks_bench".freeze

      module_function

      # Boots the workload's domain on `adapter` and times its commands.
      #
      # @param workload [Workload] the commands to dispatch
      # @param adapter [Symbol] one of `ADAPTERS`
      # @param warmup [Integer] cycles dispatched and discarded before timing starts
      # @param iterations [Integer] cycles timed
      # @return [Run] the timings of the measured cycles
      # @raise [ArgumentError] if `adapter` is not one of `ADAPTERS`
      # @raise [StandardError] whatever refusal a command raises, warmup included, since a
      #   benchmark that swallowed one would be timing something other than its workload
      def call(workload, adapter:, warmup:, iterations:)
        unless ADAPTERS.include?(adapter)
          raise ArgumentError, "unknown adapter #{adapter.inspect} — one of #{ADAPTERS.join(', ')}"
        end

        load_dependencies
        schema = "bench_#{Process.pid}_#{rand(1 << 32).to_s(16)}"
        quietly_for_postgres do
          boot(workload, adapter, schema) do |runtime|
            workload.setup.each { |step| dispatch(runtime, step) }
            measure(runtime, workload, warmup: warmup, iterations: iterations)
          end
        end
      ensure
        drop_schema(schema) if schema && POSTGRES_ADAPTERS.include?(adapter)
      end

      # Boots the workload's domain on `adapter` in an isolated copy.
      #
      # @param workload [Workload] the domain to boot
      # @param adapter [Symbol] one of `ADAPTERS`
      # @param schema [String] the scratch schema name, used only by the Postgres adapters
      # @yield [Hecks::Runtime] the booted domain
      # @return [Object] whatever the block returns
      def boot(workload, adapter, schema)
        Hecks::Fuzzing::IsolatedBoot.call(workload.domain_path, adapter: adapter, database: DATABASE,
                                          schema: schema, scratch: { database: DATABASE, schema: schema }) do |copy|
          yield Hecks.boot(copy, install_facade: false)
        end
      end

      # Keeps Postgres's `schema already exists` notices off stderr while a block runs.
      #
      # Every aggregate opens its own connection and each one repeats the notice, which
      # buries the progress lines. The server setting is restored afterwards.
      #
      # @yield the work to run with notices quieted
      # @return [Object] whatever the block returns
      def quietly_for_postgres
        previous = ENV.fetch("PGOPTIONS", nil)
        ENV["PGOPTIONS"] = [previous, "-c client_min_messages=warning"].compact.join(" ")
        yield
      ensure
        ENV["PGOPTIONS"] = previous
      end

      # Dispatches warmup cycles untimed, then times the measured ones.
      #
      # @param runtime [Hecks::Runtime] the booted domain
      # @param workload [Workload] the commands to dispatch
      # @param warmup [Integer] cycles to discard
      # @param iterations [Integer] cycles to time
      # @return [Run] the timings of the measured cycles
      def measure(runtime, workload, warmup:, iterations:)
        warmup.times { |n| workload.cycle(n).each { |step| dispatch(runtime, step) } }
        GC.start
        samples = []
        started = now
        iterations.times do |n|
          workload.cycle(warmup + n).each { |step| samples << [step.verb, time { dispatch(runtime, step) }] }
        end
        Run.new(samples: samples, wall_seconds: now - started)
      end

      # Sends one step to the runtime.
      #
      # @param runtime [Hecks::Runtime] the booted domain
      # @param step [Workload::Step] the command to dispatch
      # @return [Object] whatever `dispatch_flat` answers
      def dispatch(runtime, step)
        runtime.dispatch_flat(step.verb, step.ruby_args)
      end

      # Reads the monotonic clock.
      #
      # @return [Float] seconds on the monotonic clock
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Times a block.
      #
      # @yield the work to time
      # @return [Float] seconds the block took
      def time
        started = now
        yield
        now - started
      end

      # Loads what booting a domain on every adapter needs.
      #
      # @return [void]
      def load_dependencies
        require "hecks"
        require "hecks/fuzzing"
        require "hecks/ports/persistence/plugins/era"
      end

      # Removes the schema a Postgres run created, so repeated runs do not accumulate.
      #
      # @param schema [String] the schema name this run used
      # @return [void]
      def drop_schema(schema)
        require "pg"
        connection = PG.connect(dbname: DATABASE, connect_timeout: 2)
        connection.exec("SET client_min_messages = warning")
        connection.exec("DROP SCHEMA IF EXISTS #{connection.quote_ident(schema)} CASCADE")
      rescue LoadError, PG::Error
        nil
      ensure
        connection&.close
      end
    end
  end
end
