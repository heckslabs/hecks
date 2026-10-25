require_relative "../../bulk/sweep"
require_relative "bulk_parity"

module Hecks
  module Fuzzing
    module Properties
      # Property: a bulk run carried out as one statement (ADR 0128) answers the same per-row
      # outcomes, leaves the same records and emits the same events as the same run sent row by
      # row. It boots twice itself, like {BulkParity}, and applies only to a SQL store.
      module SetTransformParity
        # The stores that answer a set transform.
        ADAPTERS = %i[sqlite postgres].freeze

        # Replays `steps` twice on `adapter`. After the first, every pair is swept letting the run
        # compile to one statement; after the second, every pair is swept row by row. Each pair's
        # outcomes, the events it emitted and the records left after it must agree.
        #
        # @param domain_path [String] the domain directory
        # @param steps [Array<Hash>] a generated or recorded step list
        # @param adapter [Symbol] the persistence both boots are bound to
        # @return [true, String] true when they agree, or not applicable; otherwise the first pair
        #   that differs
        def set_transform_matches_row_by_row(domain_path, steps, adapter: :sqlite)
          return true unless ADAPTERS.include?(adapter) && BulkParity.attaches_bulk?(domain_path)

          compiled = SetTransformParity.played(domain_path, steps, adapter, set_transform: true)
          by_row = SetTransformParity.played(domain_path, steps, adapter, set_transform: false)
          SetTransformParity.verdict(compiled, by_row)
        end

        module_function

        # Boots a copy, plays `steps`, then sweeps every pair in order.
        #
        # @return [Array<Array>] per pair: its label, outcomes, emitted events and records after it
        def played(domain_path, steps, adapter, set_transform:)
          IsolatedBoot.call(domain_path, adapter: adapter) do |copy|
            runtime = Hecks.boot(copy, environment: nil)
            Replay::Session.new(runtime).play(steps)
            BulkParity.pairs(runtime).map { |pair| swept(runtime, pair, set_transform) }
          end
        end

        def swept(runtime, pair, set_transform)
          log = runtime.events
          before = log.size
          outcomes = sweep(runtime, pair, set_transform)
          [pair.label, outcomes, log.drop(before).map { |event| event_facts(event) }, Replay.snapshot_instances(runtime)]
        end

        def sweep(runtime, pair, set_transform)
          plan = Bulk::Plan.new(verb: pair.verb, over: pair.over, arguments: {}, mode: "best_effort")
          Bulk::Sweep.new(runtime.registry, plan, set_transform: set_transform).outcomes
        rescue StandardError => e
          [:crashed, e.class.name]
        end

        def event_facts(event) = [event.name, event.aggregate, event.id.to_s, event.payload]

        # The first pair the two runs disagree on, or true.
        def verdict(compiled, by_row)
          index = compiled.each_index.find { |at| compiled[at] != by_row[at] }
          return true unless index

          label, outcomes, events, = compiled[index]
          _, row_outcomes, row_events, = by_row[index]
          "#{label}: as one statement a bulk run answered #{outcomes.inspect} and emitted #{events.inspect}; " \
            "row by row it answered #{row_outcomes.inspect} and emitted #{row_events.inspect}"
        end
      end
    end
  end
end
