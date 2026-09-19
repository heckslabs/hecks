module Hecks
  module Fuzzing
    module Properties
      # Angle-9 — `corrects` (retroactive correction) had exactly one
      # declaration anywhere in the corpus (`examples/banking/bluebook/
      # deposit_accounts.bluebook:353`, aggregate-level) and no property
      # anywhere in this file ever checked it, and no `FEATURE_COVERAGE`
      # claim either — confirmed absent before this file existed. `qa/
      # stress_domains/corrections` gives it its first real coverage; see
      # that domain's own NOTES.md for what it found (an entity-level
      # `corrects` crashes Ruby at dispatch outright, and Rust's own
      # generated code has no admissibility check for it at all — neither
      # engine can be compared on the untested combination this property
      # was written to watch, which is itself the headline finding).
      module Corrections
        # Every event named by a `corrects` mutation, on any command a
        # booted history's own bluebooks declare — aggregate-level, or
        # nested inside an entity at any depth (`each_command_including_
        # entities`, below, is the same recursive walk `SequenceGenerator::
        # Catalog#each_entity_chain` already uses, for the identical reason:
        # `Aggregate#entities`/`Entity#entities` nest, ADR 0026, S17). For
        # every such command, every event this history actually recorded
        # under one of the command's own `emits` names must have an event
        # named by the command's own `corrects` target — same aggregate-
        # qualified name, same id — appearing strictly earlier in the same
        # history.
        #
        # `history[:events]` is already in occurrence order (`Replay.call`'s
        # own `runtime.events`, appended as each step dispatches) — "earlier"
        # is therefore "earlier in this array," no timestamp comparison
        # needed, and no per-step attribution back to which command produced
        # which event is needed either: an event's own declared name already
        # identifies the one command in its aggregate that can produce it
        # (`AggregateBuilder::Sealing#seal_correction_targets`'s own
        # `emitted_by` hash reads the identical fact, one level shallower).
        #
        # Why this cannot be `GUARANTEED_BY_CONSTRUCTION` the way the
        # aggregate-level case almost is: `CommandRules::Admissibility#
        # enforce_correction_target` (the dispatch-time check) and
        # `AggregateBuilder::Sealing#seal_correction_targets` (the build-time
        # check) both exist only for an aggregate-level `corrects` —
        # `EntityInterpreter#step_enforce_givens` never calls the former at
        # all, and the latter walks only `@commands` (the aggregate's own
        # top-level list), never `@entities`. An entity-level `corrects`
        # mutation is invisible to both doors today — this property is the
        # only thing anywhere, on either engine, that would ever catch one
        # going wrong.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true if every event emitted by a `corrects`-bearing
        #   command has a matching, strictly earlier corrected event in the same
        #   history; otherwise a message listing every unmatched correction
        def corrections_reference_an_emitted_event(history)
          violations = []

          (history[:bluebooks] || {}).each do |domain, bluebook|
            bluebook.aggregates.each do |aggregate|
              aggregate_key = "#{domain}::#{aggregate.hecks_name}"

              each_command_including_entities(aggregate) do |command|
                corrects_mutations = command.mutations.select { |mutation| mutation.op == :corrects }
                next if corrects_mutations.empty?

                corrects_mutations.each do |mutation|
                  corrected_event = mutation.target.to_s

                  command.emits.each do |produced_event_name|
                    violations.concat(unmatched_corrections(history[:events], aggregate_key,
                                                            produced_event_name.to_s, corrected_event,
                                                            command.hecks_name))
                  end
                end
              end
            end
          end

          violations.empty? || violations.uniq.join("; ")
        end

        # Finds every occurrence of `produced_event_name`, on `aggregate_key`, with no
        # matching `corrected_event` for the same id appearing earlier in `events`.
        #
        # @param events [Array<Hash>] `history[:events]`, in occurrence order
        # @param aggregate_key [String] `"domain::AggregateName"` the events belong to
        # @param produced_event_name [String] name of the event a `corrects` mutation's
        #   command emits
        # @param corrected_event [String] name of the event the mutation claims to correct
        # @param command_name [String] the command's own `hecks_name`, for the message
        # @return [Array<String>] one message per occurrence with no matching earlier
        #   corrected event; empty when every occurrence is matched
        def unmatched_corrections(events, aggregate_key, produced_event_name, corrected_event, command_name)
          own_events = events.each_with_index.select do |event, _index|
            event[:name] == produced_event_name && event[:aggregate] == aggregate_key
          end

          own_events.filter_map do |event, index|
            preceding = events.first(index)
            next if preceding.any? do |earlier|
              earlier[:name] == corrected_event && earlier[:aggregate] == aggregate_key &&
              earlier[:id].to_s == event[:id].to_s
            end

            "#{command_name} (#{aggregate_key}##{event[:id]}) emitted #{produced_event_name}, claiming to " \
              "correct #{corrected_event}, but no #{corrected_event} for the same aggregate/id appears " \
              "earlier in this history"
          end
        end

        # Yields every command declared on `owner`, then recurses into each of its
        # entities to yield theirs too, at any nesting depth (ADR 0026, S17).
        #
        # @param owner [Bluebook::Aggregate, Bluebook::Entity] the aggregate or entity
        #   whose own commands, and whose entities' commands, to walk
        # @yield [command] once per declared command, aggregate-level or nested
        # @yieldparam command [Bluebook::Command] a command declared on `owner` or one
        #   of its entities
        # @return [void]
        def each_command_including_entities(owner, &block)
          owner.commands.each(&block)
          owner.entities.each { |entity| each_command_including_entities(entity, &block) }
        end
      end
    end
  end
end
