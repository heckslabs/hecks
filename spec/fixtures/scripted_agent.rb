module Hecks
  module Adapters
    # THE DETERMINISTIC `agent` FULFILLMENT — a hand-loaded queue of raw
    # answers, one queue per operation, so a spec (or `bin/interview`
    # run against it deliberately) can assert on an EXACT question,
    # proposal, finding, or suggestion with no live model in the room.
    # `reset!` mirrors `SequentialIdentity`'s own convention: this
    # module's state is class-level, not per-boot, so a spec that wants
    # a clean queue calls it explicitly.
    #
    # RETURNS RAW HASHES, same shape a real `claude` reply unwraps to —
    # this double stands in for `ClaudeCode.call`, not for
    # `Ports::Agent`'s own validation, so a scripted answer still has to
    # survive `Ports::Agent::Answers` exactly like a live one does. A
    # spec proving the loop works against this double is also,
    # incidentally, a spec proving the validation is real.
    #
    # NEVER required from `driven.rb`, the same trap `SequentialIdentity`
    # already documents there: a second adapter answering the `agent`
    # port unconditionally would make the port permanently ambiguous
    # for every consumer, not just the specs that asked for this one.
    module ScriptedAgent
      module_function

      # Queues one answer (a raw Hash) per call, in order, for `op`
      # (`:ask`/`:interpret`/`:critique`/`:name`). Call again to append
      # more onto the same queue.
      def script(op, *answers)
        @queues ||= {}
        (@queues[op] ||= []).concat(answers)
      end

      def reset! = @queues = {}

      def ask(state:, asked:) = next_answer(:ask, state: state, asked: asked)
      def interpret(prose:, state:) = next_answer(:interpret, prose: prose, state: state)

      def critique(declared:, refusals:, findings:)
        next_answer(:critique, declared: declared, refusals: refusals, findings: findings)
      end

      # `suggest_name`, not `name` — see `Ports::Agent#suggest_name`'s
      # own comment: a module-function called `name` shadows `Module
      # #name` and breaks anything that later asks this module its own
      # name (RSpec's own failure formatting, for one — measured).
      def suggest_name(meaning:, kind:, near:) = next_answer(:name, meaning: meaning, kind: kind, near: near)

      def next_answer(op, **call)
        @queues ||= {}
        queue = @queues[op]
        if queue.nil? || queue.empty?
          raise Hecks::Ports::Agent::Unavailable,
                "ScriptedAgent has no #{op} answer queued — called with #{call.inspect}"
        end

        queue.shift
      end
    end
  end
end
