require "securerandom"
require_relative "../caller"

module Hecks
  module Runtime
    class Dispatcher
      # Leaves a `CommandRefused` fact when a caller's own command is refused, then lets the
      # refusal go on unchanged. Only a top-level, non-reaction dispatch is recorded: a reaction's
      # refusal is in the reaction log, a dry run never reaches here, and a refused `Record` is
      # never recorded again. Nothing is recorded where the Refusal member is not attached.
      module RefusalRecording
        RECORD_VERB  = "Refusal::CommandRefusal.Record".freeze
        CONTROL_KEYS = %i[to with saga_correlation dispatch_key].freeze

        private

        # @param call [Routing::Call] the refused call
        # @param refusal [Hecks::Refused] what was refused
        # @return [void]
        def record_refusal(call, refusal)
          return unless recordable?(call)

          dispatch(RECORD_VERB, with: refusal_facts(call, refusal))
        rescue Hecks::Refused, Runtime::StaleWrite
          nil
        end

        def recordable?(call)
          Thread.current[:hecks_reaction_depth].to_i.zero? && !Caller.reacting? &&
            call.verb != RECORD_VERB && @registry.verbs.include?(RECORD_VERB)
        end

        def refusal_facts(call, refusal)
          { refusal: { value: SecureRandom.uuid }, command: { value: call.verb.to_s },
            given: { value: (refusal.rule || refusal.message).to_s.then { |text| text.empty? ? "refused" : text } },
            arguments: { value: argument_names(call) }, issuer: { value: issuer_name } }
        end

        def argument_names(call)
          ((call.with || {}).keys + (call.flat || {}).keys).map(&:to_s).uniq.sort
            .reject { |name| CONTROL_KEYS.include?(name.to_sym) }.join(",")
        end

        def issuer_name
          caller = Caller.current
          (caller&.actor_id || caller&.role).to_s
        end
      end
    end
  end
end
