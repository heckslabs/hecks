module Hecks
  module Fuzzing
    module Properties
      # Property: every `corrects` mutation points at an earlier event in the same history.
      module Corrections
        # Every event emitted by a command with a `corrects` mutation, aggregate-level or
        # nested in entities, needs an earlier event with the corrected name and same id.
        #
        # `history[:events]` is in occurrence order, so "earlier" is array position.
        # Entity-level `corrects` is checked by neither dispatch nor build, so only this
        # property catches it going wrong.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true if every event emitted by a `corrects`-bearing
        #   command has a matching, strictly earlier corrected event in the same
        #   history; otherwise a message listing every unmatched correction
        def corrections_reference_an_emitted_event(history)
          violations = []

          (history[:bluebooks] || {}).each do |domain, bluebook|
            bluebook.aggregates.each do |aggregate|
              violations.concat(aggregate_corrections(history[:events], "#{domain}::#{aggregate.hecks_name}", aggregate))
            end
          end

          violations.empty? || violations.uniq.join("; ")
        end

        # Every unmatched correction among the commands of `aggregate` and its entities.
        def aggregate_corrections(events, aggregate_key, aggregate)
          found = []
          each_command_including_entities(aggregate) do |command|
            command.mutations.select { |mutation| mutation.op == :corrects }.each do |mutation|
              command.emits.each do |produced_event_name|
                found.concat(unmatched_corrections(events, aggregate_key, produced_event_name.to_s,
                                                   mutation.target.to_s, command.hecks_name))
              end
            end
          end
          found
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
            next if corrected_earlier?(events.first(index), aggregate_key, corrected_event, event)

            "#{command_name} (#{aggregate_key}##{event[:id]}) emitted #{produced_event_name}, claiming to " \
              "correct #{corrected_event}, but no #{corrected_event} for the same aggregate/id appears " \
              "earlier in this history"
          end
        end

        # Whether `preceding` holds the corrected event for `event`'s aggregate and id.
        def corrected_earlier?(preceding, aggregate_key, corrected_event, event)
          preceding.any? do |earlier|
            earlier[:name] == corrected_event && earlier[:aggregate] == aggregate_key &&
              earlier[:id].to_s == event[:id].to_s
          end
        end

        # Yields every command on `owner` and, recursively, on its entities (ADR 0026).
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
