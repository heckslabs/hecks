module Hecks
  module Runtime
    class Dispatcher
      # Leaves a `CommandRefused` fact for a command a caller issued and the domain refused, when
      # the booted world carries the Refusal member. Only a caller's own command is recorded: a
      # reaction's refusal is in the reaction log, a dry run never dispatches, and a refused
      # `Record` is not recorded again. Values are never carried, only the argument names.
      module RefusalRecord
        RECORD = "Refusal::CommandRefusal.Record".freeze

        private

        # Runs the block; a refusal it raises is recorded, then raised again unchanged.
        def recording_refusal(call)
          yield
        rescue Hecks::Refused => e
          record_refusal(call, e) if recordable?(call)
          raise
        end

        def recordable?(call)
          Thread.current[:hecks_reaction_depth].to_i.zero? && !Caller.reacting? &&
            !Thread.current[:hecks_recording_refusal] && call.verb != RECORD && @registry.verbs.include?(RECORD)
        end

        def record_refusal(call, refusal)
          Thread.current[:hecks_recording_refusal] = true
          dispatch_flat(RECORD, **refusal_facts(call, refusal))
        rescue Hecks::Refused
          nil
        ensure
          Thread.current[:hecks_recording_refusal] = false
        end

        def refusal_facts(call, refusal)
          { refusal: { value: "refusal-#{events.size + 1}" }, command: { value: call.verb.to_s },
            given: { value: (refusal.rule || refusal.message).to_s },
            arguments: { value: argument_names(call).join(",") },
            issuer: { value: issuer_name } }
        end

        def argument_names(call)
          (call.flat.keys + (call.with || {}).keys).map(&:to_s).uniq.sort - %w[to with dispatch_key saga_correlation]
        end

        def issuer_name
          current = Caller.current
          (current&.actor_id || current&.role).to_s
        end
      end
    end
  end
end
