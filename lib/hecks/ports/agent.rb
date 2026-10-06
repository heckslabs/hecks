require_relative "../runtime/registry"

module Hecks
  module Ports
    # The interviewer: asks questions, reads prose into proposed declarations, critiques a
    # model on taste, and suggests names. One adapter per process.
    module Agent
      NAME = "agent".freeze

      # The adapter's answer arrived but was unusable; retrying the same prompt will not help.
      class ValidationError < StandardError
      end

      # Nothing answered (missing binary, dead subprocess, timeout); retry or ask the human.
      class Unavailable < StandardError
      end

      # keyword_init Structs raise on an undeclared key, so an invented field fails at the edge.

      # One question; `because` is the reasoning shown to the human.
      Question = Struct.new(:text, :because, keyword_init: true)

      # `arguments` are `{name:, field:, value:}` rows, as `bin/interview propose --arg` takes.
      Proposal = Struct.new(:verb, :arguments, :rationale, keyword_init: true)

      # Kinds are closed: an open kind is an open prompt, and an open prompt drifts.
      CRITIQUE_KINDS = %i[
        anemic_aggregate wrong_boundary crud_verb leaky_value_object
        missing_lifecycle missing_invariant ubiquitous_language
        overreaching_identity untold_rule
      ].freeze
      SEVERITIES = %i[error warning].freeze

      # Same shape as `Bluebook::ModelCheck::Finding`, so gaps and critiques sort together.
      Finding = Struct.new(:kind, :severity, :subject, :message, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{kind.to_s.ljust(20)} #{subject}  —  #{message}"
      end

      # `rejected` holds the near-misses and why each was passed over.
      Suggestion = Struct.new(:name, :because, :rejected, keyword_init: true)

      # Adapters return plain Hashes; validating here makes every adapter refuse the same way.
      module_function

      # Asks the adapter for the next question.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param state [Hash] declaration plus gaps; adapters keep no memory between calls
      # @param asked [Array<Object>] questions already asked, so the adapter does not repeat one
      # @return [Array<Ports::Agent::Question>]
      # @raise [Ports::Agent::ValidationError] unless the answer is a Hash whose `"questions"`
      #   rows each carry a non-blank `"text"` and `"because"`
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer
      # @raise [Runtime::WiringError] unless exactly one adapter implements the port
      def ask(registry, state:, asked: [])
        Answers.questions(adapter(registry).ask(state: state, asked: asked))
      end

      # Turns a sentence into proposed declarations; `[]` when it named none.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param prose [String] a human's plain-English sentence
      # @param state [Hash] declaration plus gaps
      # @return [Array<Ports::Agent::Proposal>]
      # @raise [Ports::Agent::ValidationError] unless the answer is a Hash whose `"proposals"`
      #   rows have a `Chapter::Aggregate.Command` verb, a rationale and named arguments
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer
      # @raise [Runtime::WiringError] unless exactly one adapter implements the port
      def interpret(registry, prose:, state:)
        Answers.proposals(adapter(registry).interpret(prose: prose, state: state))
      end

      # Asks the adapter to judge a declared model on taste.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param declared [Hash] the chapter as declared so far
      # @param refusals [Array<Object>] refusals the language already raised
      # @param findings [Array<Object>] `Session#gaps` findings; both are passed so the
      #   adapter spends its judgement on what neither can see
      # @return [Array<Ports::Agent::Finding>]
      # @raise [Ports::Agent::ValidationError] if a kind is outside `CRITIQUE_KINDS` or a
      #   severity outside `SEVERITIES`
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer
      def critique(registry, declared:, refusals: [], findings: [])
        Answers.findings(adapter(registry).critique(declared: declared, refusals: refusals, findings: findings))
      end

      # Suggests names for a construct.
      #
      # Not called `name`: a module function of that name shadows `Module#name`.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param meaning [String] what the new name needs to mean
      # @param kind [String] the construct being named, such as `"event"`
      # @param near [Array<String>] names already in use; a suggestion must not collide
      # @return [Array<Ports::Agent::Suggestion>]
      # @raise [Ports::Agent::ValidationError] unless the answer is a Hash whose `"names"`
      #   rows each carry a non-blank `"name"` and `"because"`
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer
      def suggest_name(registry, meaning:, kind:, near: [])
        Answers.suggestions(adapter(registry).suggest_name(meaning: meaning, kind: kind, near: near))
      end

      # Finds the single adapter bound to this port.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Module] the adapter module or class implementing this port
      # @raise [Runtime::WiringError] if none, or more than one, implements the port, or the
      #   one that does has no Ruby implementation under `Hecks::Adapters`
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can conduct an interview" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end

require_relative "agent/answers"
