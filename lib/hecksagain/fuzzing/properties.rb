require_relative "../bluebook/model_check"

module Hecksagain
  module Fuzzing
    # Declared properties, checked over a REPLAYED history — the other
    # half of property-based testing the fuzzer was missing: it already
    # generates and (with bin/fuzz's shrinker) minimizes, but checked
    # nothing beyond "did the interpreter crash" and "did the replay
    # match the claim." A property here is a fact that should hold of
    # ANY history a valid domain produces, independent of which seed
    # produced it.
    #
    # Each property is `name => ->(history) { true/false, or a message
    # string naming what broke }` — a truthy return (including `true`)
    # is a pass; a String return is a failure, and the string IS the
    # finding. `history` is Replay's return shape.
    module Properties
      module_function

      # Every lifecycle field a replay leaves an instance holding is one
      # of the aggregate's OWN declared states — the full set, not just
      # `Lifecycle#states`' default+targets (see ModelCheck.full_states'
      # own comment on that hole). The tie to M2 is direct: the model
      # checker proves which states a domain's OWN declarations can ever
      # produce ; this proves a REAL RUN never produced anything else —
      # a coercion bug, a stale string surviving a rename, a default
      # that drifted from the declared set, would all show up here as a
      # value nothing upstream would have predicted.
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

      # Every saga advance a replay actually logged moved along an edge
      # the process manager DECLARED — `(from, to)` pairs that appear in
      # `saga_log` with `advanced: true` must be a `(handler.from_state,
      # handler.to_state)` pair some handler on that PM declares
      # (compensation edges included ; a REFUSED-triggered advance is a
      # handler like any other). A saga that advanced along a pair no
      # handler names would mean the runtime moved state the language
      # never authorized — the same trust ModelCheck's static reachability
      # rests on, checked here against what a run actually did.
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

      # THE FOUNDATIONAL ONE. `Hecksagain::Runtime` mints nothing — every
      # identity is declared and derived, never invented (see
      # command_interpreter.rb's own "NOTHING IS MINTED" — a random hex,
      # a counter, anything not reproducible from the payload, was
      # refused out of the runtime specifically because it broke this).
      # So the SAME steps, replayed against a FRESH boot, must produce
      # BYTE-IDENTICAL events, refusals, and instances — any drift here
      # is nondeterminism the runtime promised not to have: a wall-clock
      # read that leaked into compared state, a Hash iteration order a
      # comparison depended on, anything. Two independent replays, not a
      # cached one compared to itself, so a bug that corrupts the FIRST
      # run's own bookkeeping cannot pass by agreeing with itself.
      def replay_is_deterministic(domain_path, steps)
        first  = Replay.call(domain_path, steps)
        second = Replay.call(domain_path, steps)

        comparable = ->(history) { history.reject { |key, _| key == :bluebook } }
        return true if comparable.call(first) == comparable.call(second)

        "two replays of the same #{steps.length} steps produced different histories"
      end

      # THE QUERY ORACLE — differential testing within the one runtime,
      # the shape the retired cross-runtime harness should always have
      # been. Every generated ask was answered twice at the same instant
      # (Replay records both): once through whatever the aggregate is
      # actually bound to (Memory's native hook is Ports::Query::InMemory;
      # a SQL binding would compile it), once through the reference
      # interpreter's own evaluation. The two are separate, live
      # implementations of the same comparator vocabulary, and they have
      # drifted before — an adapter that ACCEPTS what the reference says
      # matches nothing, or orders what it refuses to order, shows up
      # here as a finding no self-referential adapter spec could see.
      def query_answers_match_reference(history)
        offenders = history.fetch(:queries).filter_map do |asked|
          next if asked[:error] || asked[:reference_rows].nil?
          next if asked[:rows] == asked[:reference_rows]

          "#{asked[:query]} #{asked[:args].inspect} answered #{asked[:rows].inspect} " \
            "natively but #{asked[:reference_rows].inspect} through the reference interpreter"
        end

        offenders.empty? || offenders.join("; ")
      end

      # THE STANDARD BATTERY, run over one replayed history — everything
      # above except determinism, which needs to replay TWICE itself and
      # so takes the steps directly rather than a single history.
      def check(history)
        { lifecycle_values_are_declared: lifecycle_values_are_declared(history),
          saga_advances_follow_declared_handlers: saga_advances_follow_declared_handlers(history),
          query_answers_match_reference: query_answers_match_reference(history) }
      end
    end
  end
end
