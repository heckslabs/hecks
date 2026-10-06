require "json"
require "tmpdir"
require "open3"
require_relative "../adapters/driven/heki"
require_relative "../runtime/saga_interpreter"
require_relative "self_consistency/saga_redelivery"
require_relative "self_consistency/sagas"
require_relative "self_consistency/value_objects"

module Hecks
  module Fuzzing
    # Checks that one engine agrees with itself: journal rehydration, replay idempotency and
    # value-object round trips, for Ruby and for the compiled Rust binary.
    module SelfConsistency
      extend SagaRedelivery
      extend Sagas
      extend ValueObjects

      module_function

      # Guarded like a runtime repository: these adapters bypass `RepositoryFactory.build`,
      # so an unguarded cold read here could skip the codec this pass exists to compare.
      def guarded_heki(**) = Ports::Persistence::CodecBoundary.guard!(Adapters::Heki.new(**))

      # Runs every check against the still-live runtime and the history `Replay.call` returns.
      #
      # @return [Hash{Symbol => Array<Hash>}] findings keyed by check name; empty when clean
      def check(runtime, history)
        { rehydration: check_rehydration(runtime), idempotency: check_idempotency(runtime),
          value_object_round_trip: check_value_object_round_trip(history),
          saga_rehydration: check_saga_rehydration(runtime, history),
          saga_redelivery_idempotency: check_saga_idempotency(runtime, history) }
      end

      # Rehydrating each touched aggregate from its journal must reproduce its live state.
      def check_rehydration(runtime)
        each_touched_repository(runtime).filter_map do |domain_name, aggregate, repository, entries|
          live = snapshot(repository)
          Dir.mktmpdir("hecks-self-consistency") do |tmp|
            writer     = guarded_heki(aggregate: aggregate, root: tmp)
            rehydrated = fold!(writer, tmp, aggregate, entries)
            next if rehydrated == live

            { field: "rehydration", domain: domain_name, aggregate: aggregate.hecks_name,
              live: live, rehydrated: rehydrated }
          end
        end
      end

      # Folding the same entries into the same store twice must change nothing.
      def check_idempotency(runtime)
        each_touched_repository(runtime).filter_map do |domain_name, aggregate, _repository, entries|
          Dir.mktmpdir("hecks-self-consistency") do |tmp|
            writer = guarded_heki(aggregate: aggregate, root: tmp)
            once   = fold!(writer, tmp, aggregate, entries)
            twice  = fold!(writer, tmp, aggregate, entries)
            next if once == twice

            { field: "idempotency", domain: domain_name, aggregate: aggregate.hecks_name,
              once: once, twice: twice }
          end
        end
      end

      # Seeds a fresh invocation of the binary with prior "instances" and no steps.
      # `emitted_*` fields are not stripped: no Ruby side exists to disagree with, and stripping
      # only the result would report a false divergence on every record carrying one.
      def rust_seed_round_trip(binary, _differ, seed_instances)
        stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => [], "seed" => seed_instances }))
        return { "__self_consistency_error__" => "rust binary exited #{status.exitstatus}: #{stdout}" } \
          unless status.success?

        parsed = JSON.parse(stdout)
        return { "__self_consistency_error__" => parsed["error"] } if parsed["error"]

        parsed["instances"]
      end

      # Seeding a fresh invocation with a prior run's instances must reproduce them.
      def check_rust_rehydration(binary, differ, live_instances)
        rehydrated = rust_seed_round_trip(binary, differ, live_instances)
        return [] if rehydrated == live_instances

        [{ field: "rust_rehydration", live: live_instances, rehydrated: rehydrated }]
      end

      # A second seed round trip must not drift from the first.
      def check_rust_idempotency(binary, differ, live_instances)
        once  = rust_seed_round_trip(binary, differ, live_instances)
        twice = rust_seed_round_trip(binary, differ, once)
        return [] if once == twice

        [{ field: "rust_idempotency", once: once, twice: twice }]
      end

      # Every [domain, aggregate, repository, entries] tuple with at least one journal entry.
      def each_touched_repository(runtime)
        found = []
        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.aggregates.each do |aggregate|
            repository = runtime.registry.repository(domain_name, aggregate)
            entries    = repository.entries
            next if entries.empty?

            found << [domain_name, aggregate, repository, entries]
          end
        end
        found
      end

      # Stored records keyed by stringified id, materialized for comparison with a cold read.
      def snapshot(repository)
        repository.all.to_h { |record| [record.id.to_s, Runtime::Value.materialize(record.state)] }
      end

      # Folds `entries` into `writer`, then reads back through a fresh `Heki` instance so the
      # result comes from disk rather than the writer's cache. Calling it twice on one writer
      # replays the journal a second time.
      def fold!(writer, tmp, aggregate, entries)
        entries.each do |entry|
          writer.append(entry)
          writer.project(entry)
        end

        guarded_heki(aggregate: aggregate, root: tmp).all
                                                     .to_h do |record|
          [
            record.id.to_s, Runtime::Value.materialize(record.state)
          ]
        end
      end
    end
  end
end
