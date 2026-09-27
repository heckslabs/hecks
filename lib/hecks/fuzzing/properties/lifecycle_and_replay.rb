require_relative "../nondeterministic"

module Hecks
  module Fuzzing
    module Properties
      # Properties over declared lifecycle states, saga edges and replay determinism.
      module LifecycleAndReplay
        # Every lifecycle field a replay leaves holds one of the aggregate's declared states.
        #
        # Uses the full state set (`ModelCheck.full_states`), not just `Lifecycle#states`.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each offending instance
        def lifecycle_values_are_declared(history)
          bluebook = history.fetch(:bluebook)
          declared = {}
          bluebook.aggregates.each do |aggregate|
            declared[aggregate.hecks_name] = Bluebook::ModelCheck.full_states(aggregate.lifecycle) if aggregate.lifecycle
          end
          return true if declared.empty?

          offenders = history.fetch(:instances).filter_map do |key, state|
            aggregate_name = key.split("::").last.split("#").first
            states = declared[aggregate_name]
            next unless states

            lifecycle = bluebook.aggregate(aggregate_name).lifecycle
            value = state[lifecycle.field]
            next if value.nil? || states.include?(value.to_s)

            "#{key} holds #{lifecycle.field}=#{value.inspect}, which #{aggregate_name} never declares as a state"
          end

          offenders.empty? || offenders.join("; ")
        end

        # Every logged saga advance follows a `(from_state, to_state)` pair some handler declares.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true, or a message naming the process manager and undeclared pair
        def saga_advances_follow_declared_handlers(history)
          bluebook = history.fetch(:bluebook)
          edges = Hash.new { |h, k| h[k] = [] }
          bluebook.process_managers.each do |pm|
            pm.handlers.each { |handler| edges[pm.name] << [handler.from_state, handler.to_state] }
          end
          return true if edges.empty?

          offenders = history.fetch(:sagas).filter_map do |entry|
            next unless entry[:advanced]

            pair = [entry[:from], entry[:to]]
            next if edges[entry[:process_manager]].include?(pair)

            "#{entry[:process_manager]} advanced #{pair.inspect}, which no declared handler names"
          end

          offenders.empty? || offenders.join("; ")
        end

        # Replaying the same steps on a fresh boot yields identical events, refusals and instances.
        #
        # The runtime mints no identity, so drift is nondeterminism (a clock read, hash order).
        # Two independent replays are compared so a corrupted first run cannot agree with itself.
        #
        # @param domain_path [String] the domain directory to boot, such as `"examples/pizzas"`
        # @param steps [Array<Hash>] the step list to replay twice
        # @param adapter [Symbol] persistence adapter (`:memory`, `:postgres`, or `:postgres_era`)
        # @return [true, String] true, or a message naming the step count that diverged
        def replay_is_deterministic(domain_path, steps, adapter: :memory)
          first  = Replay.call(domain_path, steps, adapter: adapter)
          second = Replay.call(domain_path, steps, adapter: adapter)

          # What is stripped is declared in `Nondeterministic::FIELDS`. Outbox rows are stripped
          # per row, not dropped, so status, consumer and event payload stay checked.
          strip_outbox_nondeterminism = lambda do |history|
            traces = Array(history[:outbox_traces]).map do |trace|
              trace.merge(rows: trace[:rows].map do |row|
                Nondeterministic.strip(row, :outbox_row).merge(event: Nondeterministic.strip(row[:event], :event))
              end)
            end
            history.merge(outbox_traces: traces)
          end

          comparable = ->(history) { Nondeterministic.strip(strip_outbox_nondeterminism.call(history), :history) }
          return true if comparable.call(first) == comparable.call(second)

          "two replays of the same #{steps.length} steps produced different histories"
        end
      end
    end
  end
end
