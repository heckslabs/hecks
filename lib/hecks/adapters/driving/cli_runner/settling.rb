require "json"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The answer `--wait` gives once every reaction has run. Extended into `CliRunner`.
        module Settling
          # The answer `--wait` gives: the record re-read after every reaction has run, with all its
          # events, and a status of 1 when its lifecycle ended in a failure state, a refused
          # reaction
          # blocks the run or a reaction crashed.
          #
          # A refusal blocks unless a sibling reaction delivered another command on the same
          # aggregate (`Runtime::ReactionOutcome`). The settled record is always the text, so a
          # failed
          # run pipes like a passing one; the reason a human reads is a third element.
          #
          # @return [Array(String, Integer)] the JSON and the status, plus (Array(String, Integer,
          #   String)) why the run failed when it did
          def settled(runtime, spec, handle, bluebook, launcher, extra) # rubocop:disable Metrics/ParameterLists -- pinned by the callers and specs
            why = reactions_failed(handle)
            return finish(stateless_json(handle, extra), why) if handle.state.nil?

            aggregate = aggregate_of(bluebook, spec)
            state     = reread(runtime, bluebook, aggregate, handle) || handle.state
            answer    = settled_answer(handle, state, settled_event_names(runtime, bluebook, aggregate, handle), extra)
            why      += failure_reasons(aggregate, state, launcher)
            settled_result(answer, LauncherOptions.report?(launcher, spec), why)
          end

          # The settled answer as the launcher's report when it prints one, else as JSON.
          def settled_result(answer, report, why)
            report ? report_of(answer[:state], why) : finish(JSON.pretty_generate(answer), why)
          end

          # The JSON of a port operation's outcome, which has no record to re-read.
          def stateless_json(handle, extra)
            JSON.pretty_generate(answered(handle).merge(extra))
          end

          # The record, as the JSON answer holds it, with the names of its events.
          def settled_answer(handle, state, events, extra)
            { id: handle.id, state: Json.materialize(state), events: events }.merge(extra)
          end

          # The names of the events the record's run emitted, as the runtime now holds them.
          def settled_event_names(runtime, bluebook, aggregate, handle)
            fqn    = "#{bluebook.name}::#{aggregate&.hecks_name}"
            events = runtime.events.select { |event| event.aggregate == fqn && event.id == handle.id }
            (events.empty? ? handle.events : events).map(&:name)
          end

          # The sentence for a record that ended in a failure state, as a list: empty otherwise.
          def failure_reasons(aggregate, state, launcher)
            return [] unless LauncherOptions.failed?(aggregate, state, launcher)

            [failure_sentence(aggregate, state, aggregate.lifecycle.field)]
          end

          # The answer of a command the launcher prints as its report: the text it recorded, with
          # the status 1 when the run failed, and nothing else.
          def report_of(state, why)
            text = state[why.empty? ? :output : :refusal]
            text = text[:value] if text.is_a?(Hash)
            text = why.join("\n") if text.to_s.strip.empty?
            [text.to_s, why.empty? ? 0 : 1]
          end

          # The sentence for a record that ended in a failure state: the state, then the record's
          # own
          # `refusal` when it keeps one, without the class name an adapter's failure carries.
          def failure_sentence(aggregate, state, field)
            sentence = "#{aggregate.hecks_name} ended in the failure state #{state[field.to_sym].to_s.inspect}"
            refusal  = state[:refusal]
            refusal  = refusal.value if refusal.respond_to?(:value)
            refusal  = refusal[:value] if refusal.is_a?(Hash)
            return sentence if refusal.to_s.strip.empty?

            "#{sentence}: #{refusal.to_s.strip.sub(/\A(\w+::)+\w+: /, "")}"
          end

          # The answer and its status: 0 when nothing failed, else 1 with the reasons joined.
          def finish(text, reasons)
            reasons.empty? ? [text, 0] : [text, 1, reasons.join("\n")]
          end

          # What the reactions of the run the handle reports did wrong: each refusal that blocks it
          # and each crash, as one sentence apiece.
          def reactions_failed(handle)
            blocking = handle.respond_to?(:blocking_reactions) ? handle.blocking_reactions : []
            crashed  = handle.respond_to?(:reaction_defects) ? handle.reaction_defects : []
            blocking.map { |row| "reaction #{row[:policy]} was refused (#{row[:trigger]}): #{row[:reason]}" } +
              crashed.map { |row| "reaction #{row[:policy]} crashed (#{row[:error_class]}): #{row[:reason]}" }
          end

          # Whether a reaction the domain refused blocks the run the handle reports.
          def blocked?(handle)
            handle.respond_to?(:blocking_reactions) && !handle.blocking_reactions.empty?
          end

          # The aggregate a top-level command belongs to; nil for an entity command or a port.
          def aggregate_of(bluebook, spec)
            head = spec[:command].split("::", 2).last
            return if head.count(".") != 1

            bluebook.aggregates.find { |aggregate| aggregate.hecks_name == head.split(".").first }
          end

          # The record as its repository holds it now, or nil when it cannot be read.
          def reread(runtime, bluebook, aggregate, handle)
            return unless aggregate && runtime.respond_to?(:registry)

            runtime.registry.repository(bluebook.name, aggregate)&.find(handle.id)&.to_h
          end
        end
      end
    end
  end
end
