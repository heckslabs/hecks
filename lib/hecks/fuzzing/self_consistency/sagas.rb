require "tmpdir"
require_relative "../../runtime/saga_interpreter"

module Hecks
  module Fuzzing
    module SelfConsistency
      # The saga rehydration check: checkpoints written through Heki and read back cold.
      # Mixed into `SelfConsistency`, whose `guarded_heki` it uses.
      module Sagas
        # A saga checkpoint written through Heki and read back cold must equal the live saga
        # instances. One finding per (domain, process manager).
        #
        # `completed_compensations` is not compared; `history[:saga_instances]` never records it.
        def check_saga_rehydration(runtime, history)
          saga_groups(runtime, history).filter_map do |domain_name, process_manager, anchor, persisted|
            saga_rehydration_finding(anchor, domain_name, process_manager, persisted)
          end
        end

        # Every `[domain, process manager, anchor aggregate, persisted conversations]` with at
        # least one live conversation.
        def saga_groups(runtime, history)
          saga_instances = history[:saga_instances] || {}
          each_domain_process_manager(runtime).filter_map do |domain_name, process_manager|
            persisted = saga_instances[process_manager.name]
            next if persisted.nil? || persisted.empty?

            anchor = runtime.registry.bluebook(domain_name).aggregates.first
            [domain_name, process_manager, anchor, persisted] if anchor
          end
        end

        # The finding for one process manager whose cold-read checkpoints differ from live, or nil.
        def saga_rehydration_finding(anchor, domain_name, process_manager, persisted)
          Dir.mktmpdir("hecks-self-consistency-saga") do |tmp|
            write_saga_checkpoints(anchor, tmp, domain_name, process_manager, persisted)
            live       = normalize_saga_rows(persisted)
            rehydrated = cold_read_saga_rows(anchor, tmp, domain_name)
            next if rehydrated == live

            { field: "saga_rehydration", domain: domain_name, process_manager: process_manager.name,
              live: live, rehydrated: rehydrated }
          end
        end

        # Writes every live conversation of `process_manager` through Heki under `tmp`.
        def write_saga_checkpoints(anchor, tmp, domain_name, process_manager, persisted)
          writer = guarded_heki(aggregate: anchor, root: tmp, settings: { domain: domain_name })
          persisted.each do |correlation, saga|
            writer.save_saga(process_manager: process_manager.name, correlation: correlation.to_s,
                             state: saga[:state], memory: saga[:memory], completed_compensations: [])
          end
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
      end
    end
  end
end
