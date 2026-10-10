require_relative "run"

module Hecks
  module Bench
    # Times the Ruby runtime's `dispatch_flat`, in-process, on one persistence adapter.
    # Boots a throwaway copy via `Fuzzing::IsolatedBoot` so every run starts from an empty store.
    module RubyRunner
      ADAPTERS = %i[memory sqlite postgres postgres_era].freeze

      POSTGRES_ADAPTERS = %i[postgres postgres_era].freeze

      DATABASE = "hecks_bench".freeze

      module_function

      def call(workload, adapter:, warmup:, iterations:)
        unless ADAPTERS.include?(adapter)
          raise ArgumentError, "unknown adapter #{adapter.inspect} — one of #{ADAPTERS.join(", ")}"
        end

        load_dependencies
        schema = "bench_#{Process.pid}_#{rand(1 << 32).to_s(16)}"
        quietly_for_postgres do
          boot(workload, adapter, schema) { |runtime| run_workload(runtime, workload, warmup, iterations) }
        end
      ensure
        drop_schema(schema) if schema && POSTGRES_ADAPTERS.include?(adapter)
      end

      def run_workload(runtime, workload, warmup, iterations)
        workload.setup.each { |step| dispatch(runtime, step) }
        measure(runtime, workload, warmup: warmup, iterations: iterations)
      end

      def boot(workload, adapter, schema)
        Hecks::Fuzzing::IsolatedBoot.call(workload.domain_path, adapter: adapter, database: DATABASE,
                                          schema: schema, scratch: { database: DATABASE, schema: schema }) do |copy|
          yield Hecks.boot(copy, install_driving: false)
        end
      end

      # Every aggregate opens its own connection and each repeats the `schema already exists`
      # notice, burying progress lines; `PGOPTIONS` is restored afterwards.
      def quietly_for_postgres
        previous = ENV.fetch("PGOPTIONS", nil)
        ENV["PGOPTIONS"] = [previous, "-c client_min_messages=warning"].compact.join(" ")
        yield
      ensure
        ENV["PGOPTIONS"] = previous
      end

      def measure(runtime, workload, warmup:, iterations:)
        warmup.times { |n| workload.cycle(n).each { |step| dispatch(runtime, step) } }
        GC.start
        samples = []
        started = now
        iterations.times { |n| samples.concat(timed_cycle(runtime, workload.cycle(warmup + n))) }
        Run.new(samples: samples, wall_seconds: now - started)
      end

      # @return [Array<Array(String, Float)>] each step's verb and how long its dispatch took
      def timed_cycle(runtime, steps)
        steps.map { |step| [step.verb, time { dispatch(runtime, step) }] }
      end

      def dispatch(runtime, step)
        runtime.dispatch_flat(step.verb, step.ruby_args)
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def time
        started = now
        yield
        now - started
      end

      def load_dependencies
        require "hecks"
        require "hecks/fuzzing"
        require "hecks/ports/persistence/plugins/era"
      end

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
