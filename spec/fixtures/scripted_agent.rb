module Hecks
  module Adapters
    # Deterministic `agent` fulfillment: one queue of raw answers per operation.
    # State is class-level, so specs call `reset!` for a clean queue.
    #
    # Stands in for `ClaudeCode.call`; answers still pass `Ports::Agent::Answers` validation.
    # Never required from `driven.rb`: a second `agent` adapter would make the port ambiguous.
    module ScriptedAgent
      module_function

      # Appends raw answers to `verb`'s queue, in dequeue order.
      #
      # @param verb [Symbol] the operation the answers are for (`:ask`, `:interpret`,
      #   `:critique`, or `:name`)
      # @param answers [Array<Hash>] raw, JSON-shaped answer Hashes to append to `verb`'s queue,
      #   in the order they will be dequeued
      # @return [void]
      def script(verb, *answers)
        @queues ||= {}
        (@queues[verb] ||= []).concat(answers)
      end

      # Clears every queued answer for every verb.
      #
      # @return [void]
      def reset! = @queues = {}

      # Returns the next scripted answer for the `ask` operation.
      #
      # @param state [Hash] the interview's current picture; passed through unused
      # @param asked [Array<Object>] the questions already asked; passed through unused
      # @return [Hash] the next raw answer Hash queued for `:ask`
      # @raise [Hecks::Ports::Agent::Unavailable] if no answer is queued for `:ask`
      def ask(state:, asked:) = next_answer(:ask, state: state, asked: asked)

      # Returns the next scripted answer for the `interpret` operation.
      #
      # @param prose [String] a human's plain-English sentence; passed through unused
      # @param state [Hash] the interview's current picture; passed through unused
      # @return [Hash] the next raw answer Hash queued for `:interpret`
      # @raise [Hecks::Ports::Agent::Unavailable] if no answer is queued for `:interpret`
      def interpret(prose:, state:) = next_answer(:interpret, prose: prose, state: state)

      # Returns the next scripted answer for the `critique` operation.
      #
      # @param declared [Hash] the chapter as declared so far; passed through unused
      # @param refusals [Array<Object>] refusals the language already raised; passed through unused
      # @param findings [Array<Object>] mechanical findings already found; passed through unused
      # @return [Hash] the next raw answer Hash queued for `:critique`
      # @raise [Hecks::Ports::Agent::Unavailable] if no answer is queued for `:critique`
      def critique(declared:, refusals:, findings:)
        next_answer(:critique, declared: declared, refusals: refusals, findings: findings)
      end

      # Named `suggest_name` because a module-function `name` would shadow `Module#name`.
      #
      # @param meaning [String] what the new name needs to mean; passed through unused
      # @param kind [String] the kind of construct being named; passed through unused
      # @param near [Array<String>] names already in use; passed through unused
      # @return [Hash] the next raw answer Hash queued for `:name`
      # @raise [Hecks::Ports::Agent::Unavailable] if no answer is queued for `:name`
      def suggest_name(meaning:, kind:, near:) = next_answer(:name, meaning: meaning, kind: kind, near: near)

      # Dequeues the next answer for `verb`.
      #
      # @param verb [Symbol] queue key to dequeue from
      # @param call [Hash] the keyword arguments the caller was invoked with, used only in the
      #   error message when the queue is empty
      # @return [Hash] the next raw answer Hash queued for `verb`
      # @raise [Hecks::Ports::Agent::Unavailable] if no answer is queued for `verb`
      def next_answer(verb, **call)
        @queues ||= {}
        queue = @queues[verb]
        if queue.nil? || queue.empty?
          raise Hecks::Ports::Agent::Unavailable,
                "ScriptedAgent has no #{verb} answer queued — called with #{call.inspect}"
        end

        queue.shift
      end
    end
  end
end
