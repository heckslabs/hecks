require "json"
require "tmpdir"
require "open3"
require_relative "../adapters/driven/heki"
require_relative "../runtime/saga_interpreter"

module Hecks
  module Fuzzing
    # Checks that one engine agrees with itself: journal rehydration, replay idempotency and
    # value-object round trips, for Ruby and for the compiled Rust binary.
    module SelfConsistency
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
        each_touched_repository(runtime).filter_map do |domain_name, aggregate, repository, entries|
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

      # Every value object the sequence built must survive `to_json` then `Value.build`.
      #
      # The owning aggregate is passed to `build` so nested composite fields resolve; with `nil`
      # they come back as bare Hashes, a false positive. Query rows are skipped because they
      # name no single owning aggregate.
      def check_value_object_round_trip(history)
        bluebooks = history[:bluebooks] || {}
        seen = {}.compare_by_identity
        found = []

        history[:instances].each do |key, state|
          domain_name, aggregate_name = key.to_s.split("#", 2).first.to_s.split("::", 2)
          aggregate = bluebooks[domain_name]&.aggregate(aggregate_name)
          walk_value_objects(state, found, seen, aggregate)
        end

        history[:events].each do |event|
          domain_name, aggregate_name = event[:aggregate].to_s.split("::", 2)
          aggregate = bluebooks[domain_name]&.aggregate(aggregate_name)
          walk_value_objects(event[:payload], found, seen, aggregate)
        end

        found.filter_map do |value, aggregate|
          begin
            rebuilt = Runtime::Value.build(value.value_object, JSON.parse(value.to_json), aggregate)
          rescue StandardError => e
            next { field: "value_object_round_trip", type: value.type_name, original: value.to_h,
                   error: "#{e.class}: #{e.message}" }
          end

          next if rebuilt == value

          { field: "value_object_round_trip", type: value.type_name, original: value.to_h,
            rehydrated: rebuilt.to_h }
        end
      end

      # A saga checkpoint written through Heki and read back cold must equal the live saga
      # instances. One finding per (domain, process manager).
      #
      # `completed_compensations` is not compared; `history[:saga_instances]` never records it.
      def check_saga_rehydration(runtime, history)
        saga_instances = history[:saga_instances] || {}
        each_domain_process_manager(runtime).filter_map do |domain_name, process_manager|
          persisted = saga_instances[process_manager.name]
          next if persisted.nil? || persisted.empty?

          anchor = runtime.registry.bluebook(domain_name).aggregates.first
          next unless anchor

          Dir.mktmpdir("hecks-self-consistency-saga") do |tmp|
            writer = guarded_heki(aggregate: anchor, root: tmp, settings: { domain: domain_name })
            persisted.each do |correlation, saga|
              writer.save_saga(process_manager: process_manager.name, correlation: correlation.to_s,
                               state: saga[:state], memory: saga[:memory], completed_compensations: [])
            end

            live       = normalize_saga_rows(persisted)
            rehydrated = cold_read_saga_rows(anchor, tmp, domain_name)
            next if rehydrated == live

            { field: "saga_rehydration", domain: domain_name, process_manager: process_manager.name,
              live: live, rehydrated: rehydrated }
          end
        end
      end

      # A rehydrated saga checkpoint must not advance when its last event is redelivered.
      #
      # The live registry slot is swapped for the cold-read checkpoint and restored in `ensure`;
      # safe because nothing reads the live registry after this runs. Only state/memory are
      # compared: a leg whose `from:` and `to:` match legitimately re-runs.
      def check_saga_idempotency(runtime, history)
        saga_instances = history[:saga_instances] || {}
        interpreter    = Runtime::SagaInterpreter.new(runtime.registry, door: runtime)

        each_domain_process_manager(runtime).flat_map do |domain_name, process_manager|
          persisted = saga_instances[process_manager.name]
          next [] if persisted.nil? || persisted.empty?

          anchor = runtime.registry.bluebook(domain_name).aggregates.first
          next [] unless anchor

          persisted.filter_map do |correlation, saga|
            redelivery = last_advancing_event(runtime, interpreter, process_manager, correlation)
            next unless redelivery

            check_one_saga_redelivery(runtime, interpreter, domain_name, process_manager, anchor,
                                      correlation, saga, redelivery)
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

      # Every [domain, process manager] pair any loaded bluebook declares.
      def each_domain_process_manager(runtime)
        found = []
        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.process_managers.each { |pm| found << [domain_name, pm] }
        end
        found
      end

      # Live saga rows with `memory` deep-stringified, matching what a Heki round trip yields.
      def normalize_saga_rows(persisted)
        persisted.each_with_object({}) do |(correlation, saga), rows|
          rows[correlation.to_s] = { state: saga[:state], memory: deep_stringify_keys(saga[:memory]) }
        end
      end

      # A fresh `Heki` reader at the same path: a new instance has no memoized store, so the
      # read goes through the on-disk snapshot and journal rather than the writer's memory.
      def cold_read_saga_rows(anchor, tmp, domain_name)
        reader = guarded_heki(aggregate: anchor, root: tmp, settings: { domain: domain_name })
        reader.each_saga.with_object({}) do |(_pm, correlation, state, memory, _completed), rows|
          rows[correlation] = { state: state, memory: deep_stringify_keys(memory) }
        end
      end

      # `SagaStore#each_saga` symbolizes only top-level `memory` keys, while the live side is
      # symbol-keyed throughout. Stringifying both sides tells that accepted difference apart
      # from real data loss.
      def deep_stringify_keys(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
        when Array then value.map { |item| deep_stringify_keys(item) }
        else value
        end
      end

      # The domain event the correlation's current checkpoint last advanced on, or nil if it
      # never advanced. Skips the synthetic `REFUSED` trigger, which has no event to redeliver.
      #
      # Uses `send(:saga_correlation)` on purpose: the private method is the real correlation
      # logic, and reimplementing it here would only approximate it.
      def last_advancing_event(runtime, interpreter, process_manager, correlation)
        entry = runtime.registry.saga_log.reverse_each.find do |row|
          row[:process_manager] == process_manager.name && row[:instance] == correlation &&
            row[:advanced] && row[:on] != Runtime::SagaInterpreter::REFUSED
        end
        return nil unless entry

        runtime.events.reverse_each.find do |event|
          event.name == entry[:on] && interpreter.send(:saga_correlation, process_manager, event) == correlation
        end
      end

      # One correlation's redelivery check, split out of `check_saga_idempotency`.
      # The `saga_log` mark/restore stays here so it sits beside the `advance` it guards.
      def check_one_saga_redelivery(runtime, interpreter, domain_name, process_manager, anchor,
                                    correlation, saga, redelivery)
        # rubocop:disable-next Metrics/BlockLength
        Dir.mktmpdir("hecks-self-consistency-saga") do |tmp|
          writer = guarded_heki(aggregate: anchor, root: tmp, settings: { domain: domain_name })
          writer.save_saga(process_manager: process_manager.name, correlation: correlation.to_s,
                           state: saga[:state], memory: saga[:memory], completed_compensations: [])

          rehydrated = guarded_heki(aggregate: anchor, root: tmp, settings: { domain: domain_name })
                       .each_saga.find { |_pm, corr, *| corr == correlation.to_s }
          next unless rehydrated

          _pm, _corr, state, memory, compensations = rehydrated
          before = { state: state, memory: deep_stringify_keys(memory) }

          saga_instances = runtime.registry.saga_instances[process_manager.name]
          original       = saga_instances[correlation]

          # `advance` appends to `saga_log` (shared by reference with the primary trace);
          # the tail is sliced back off in `ensure` so the probe does not leak into it.
          saga_log      = runtime.registry.saga_log
          saga_log_mark = saga_log.size
          begin
            saga_instances[correlation] = { state: state, memory: memory, completed_compensations: compensations || [] }
            interpreter.advance(redelivery, domain_name, only: process_manager)

            after       = saga_instances[correlation]
            after_shape = after && { state: after[:state], memory: deep_stringify_keys(after[:memory]) }
            next if after_shape == before

            { field: "saga_redelivery_idempotency", domain: domain_name, process_manager: process_manager.name,
              correlation: correlation, on: redelivery.name, before: before, after: after_shape }
          ensure
            saga_log.slice!(saga_log_mark..) if saga_log.size > saga_log_mark

            if original
              saga_instances[correlation] = original
            else
              saga_instances.delete(correlation)
            end
          end
        end
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

      # Recurses via `#[]` rather than `#to_h`, which would materialize nested values away.
      # `seen` compares by identity: a live state and an event payload can share one object,
      # while two equal but distinct value objects are still two round trips to prove.
      def walk_value_objects(node, found, seen, aggregate)
        case node
        when Runtime::Value
          return if seen[node]

          seen[node] = true
          found << [node, aggregate]
          node.value_object.attributes.each do |attribute|
            walk_value_objects(node[attribute.name], found, seen, aggregate)
          end
        when Hash
          node.each_value { |value| walk_value_objects(value, found, seen, aggregate) }
        when Array
          node.each { |value| walk_value_objects(value, found, seen, aggregate) }
        end
      end
    end
  end
end
