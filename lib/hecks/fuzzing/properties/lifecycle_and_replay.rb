module Hecks
  module Fuzzing
    module Properties
      # Lifecycle/saga-shape properties, and replay determinism itself: a
      # replayed history's lifecycle fields are among the aggregate's own
      # declared states, a saga's advances follow its declared handlers, and
      # replaying the same steps twice produces the same history.

      # Holds lifecycle_values_are_declared, saga_advances_follow_declared_handlers,
      # and replay_is_deterministic — the foundational property, since every
      # other property here trusts that a single replay's own history is
      # trustworthy in the first place.
      module LifecycleAndReplay
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

        # THE FOUNDATIONAL ONE. `Hecks::Runtime` mints nothing — every
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
        def replay_is_deterministic(domain_path, steps, adapter: :memory)
          first  = Replay.call(domain_path, steps, adapter: adapter)
          second = Replay.call(domain_path, steps, adapter: adapter)

          # `:event_uid`/`:delivery_id` — `Runtime::Outbox::Fanout#rows_for`'s
          # OWN `SecureRandom.uuid`, minted fresh per enqueue specifically so
          # it stays OFF `Event#to_h` (that file's own comment: the domain's
          # own events stay mintless; this is Ruby-only relay bookkeeping,
          # never part of what a replay claims the DOMAIN produced) — so two
          # otherwise-identical replays legitimately carry two different
          # uuids here, the same reason `:bluebook`/`:bluebooks` (live
          # object identities, not values) are excluded below.
          #
          # `row[:event][:occurred_at]` — the outbox row's own `event:` field
          # is `Outbox.serialize_event`'s `event.to_h.merge(correlation:...)`,
          # the FULL `Event#to_h`, unlike `history[:events]` (this file's own
          # `events = runtime.events.map { {name:, aggregate:, id:, payload:}
          # }`, above) which has ALWAYS deliberately left `occurred_at` OFF
          # the compared surface for exactly this reason: a wall-clock read,
          # never reproducible byte-for-byte between two independent
          # replaying processes a second apart. Stripped here the same way,
          # for the one place it newly reappears.
          #
          # Both stripped from each `outbox_traces` row before comparing
          # rather than dropping `outbox_traces` wholesale: everything else
          # on a row (status, consumer, kind, the event's own name/
          # aggregate/id/payload) IS reproducible from the steps alone and
          # stays checked.
          strip_outbox_nondeterminism = lambda do |history|
            traces = Array(history[:outbox_traces]).map do |trace|
              trace.merge(rows: trace[:rows].map do |row|
                row.except(:event_uid, :delivery_id).merge(event: row[:event].except(:occurred_at))
              end)
            end
            history.merge(outbox_traces: traces)
          end

          comparable = ->(history) { strip_outbox_nondeterminism.call(history).except(:bluebook, :bluebooks) }
          return true if comparable.call(first) == comparable.call(second)

          "two replays of the same #{steps.length} steps produced different histories"
        end
      end
    end
  end
end
