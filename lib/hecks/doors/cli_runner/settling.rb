module Hecks
  module Doors
    module CliRunner
      # The answer `--wait` gives: the record re-read after every reaction has run, with all its
      # events, and a status of 1 when its lifecycle ended in a failure state, a refused reaction
      # blocks the run or a reaction crashed.
      module Settling
        # What a settled answer is read against: the booted domain, the command's projected spec,
        # its chapter and the chapter's `launcher` setting.
        Context = Struct.new(:runtime, :spec, :bluebook, :launcher)

        module_function

        # A refusal blocks unless a sibling reaction delivered another command on the same
        # aggregate (`Runtime::ReactionOutcome`). The settled record is always the text, so a failed
        # run pipes like a passing one; the reason a human reads is a third element.
        #
        # @param context [Context] what the answer is read against
        # @param handle [Runtime::Dispatcher::Result] the outcome of the command
        # @param extra [Hash] keys added to the answer: the minted run key, refused reactions
        # @return [Array(String, Integer)] the JSON and the status, plus (Array(String, Integer,
        #   String)) why the run failed when it did
        def call(context, handle, extra)
          why = reactions_failed(handle)
          return finish(JSON.pretty_generate(Answers.answered(handle).merge(extra)), why) if handle.state.nil?

          settle(context, handle, extra, why)
        end

        # The settled answer for a command that left a record, given the reasons found so far.
        def settle(context, handle, extra, why)
          aggregate = aggregate_of(context.bluebook, context.spec)
          state     = reread(context, aggregate, handle) || handle.state
          answer    = answer_of(context, aggregate, state, handle, extra)
          why += failure_reasons(aggregate, state, context.launcher)
          return report_of(answer[:state], why) if LauncherOptions.report?(context.launcher, context.spec)

          finish(JSON.pretty_generate(answer), why)
        end

        # The record, as its repository holds it now, with the events the run caused.
        def answer_of(context, aggregate, state, handle, extra)
          fqn    = "#{context.bluebook.name}::#{aggregate&.hecks_name}"
          events = context.runtime.events.select { |event| event.aggregate == fqn && event.id == handle.id }
          { id: handle.id, state: JsonDoor.materialize(state),
            events: (events.empty? ? handle.events : events).map(&:name) }.merge(extra)
        end

        # The sentence for a record that ended in a failure state, or none when it did not.
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

        # The sentence for a record that ended in a failure state: the state, then the record's own
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

        # The aggregate a top-level command belongs to; nil for an entity command or a port.
        def aggregate_of(bluebook, spec)
          head = spec[:command].split("::", 2).last
          return if head.count(".") != 1

          bluebook.aggregates.find { |aggregate| aggregate.hecks_name == head.split(".").first }
        end

        # The record as its repository holds it now, or nil when it cannot be read.
        def reread(context, aggregate, handle)
          return unless aggregate && context.runtime.respond_to?(:registry)

          context.runtime.registry.repository(context.bluebook.name, aggregate)&.find(handle.id)&.to_h
        end
      end
    end
  end
end
