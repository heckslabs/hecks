require_relative "../runtime/registry"

module Hecks
  module Ports
    # The interviewer — whatever asks the next good question, reads a
    # sentence back into proposed declarations, judges a model on taste
    # rather than structure, or suggests a name.
    #
    # ## Why a singleton port
    #
    # Resolved the same zero/one/many way every other port here is
    # (`Ports::IdentityGeneration`'s own singleton adapter — one
    # interviewer per process, never per-aggregate), because a second
    # adapter answering this port is exactly as unchoosable as a second
    # one minting identities.
    #
    # ## Why this exists
    #
    # Built last, on purpose, and still optional. `.claude/skills/
    # interview/SKILL.md` conducts a whole session with none of this —
    # Claude Code reads `bin/interview state` itself, asks the human
    # directly with real conversation context, and calls `bin/interview
    # ask`/`propose`/`accept` itself. This port exists for what that
    # cannot reach: a headless run (`bin/interview suggest`, no model in
    # the room otherwise), a batch `critique` over an already-written
    # chapter, and — the actual point of building it at all — a
    # scripted double (`spec/fixtures/scripted_agent.rb`) that makes the
    # whole loop testable with no real model involved.
    #
    # ## What this port is not
    #
    # It does not judge whether a declaration is well-formed — that is
    # the meta-domain's own job, answered by a real dispatch refusing or
    # not (`Interview::Session#offer`). This port only ever produces
    # shape: a question, a proposed declaration, a judgement about
    # taste, a name. A proposal naming a category the language does not
    # declare is an adapter fault, refused here, in `Answers`; a
    # proposal naming a real category but describing the wrong domain
    # fact is dispatched anyway, so the language gets to say why. That
    # line is the whole design.
    #
    # ## Where parsing happens
    #
    # Parsing belongs to this file, not the adapter. An adapter answers
    # with a plain, already-JSON-shaped Hash (a real model's parsed
    # reply, or a spec double's own hand-built one) — never a Struct —
    # so every adapter is validated identically here rather than trusting
    # each one to refuse the same way. Two adapters that parsed
    # differently would mean the same malformed answer passing through
    # one and refusing through the other.
    module Agent
      NAME = "agent".freeze

      # The answer came back and could not be used — no JSON in it, a
      # category the language does not declare, a severity outside the
      # two that exist. A foreign failure (JSON::ParserError, a missing
      # key) wrapped into something this port owns, the same shape
      # `Ports::Authentication::ValidationError` already is, so no
      # caller ever rescues a raw parser error leaking out of an
      # adapter.
      class ValidationError < StandardError
      end

      # Nothing answered at all — the binary is missing, the subprocess
      # died, the call timed out. Separate from ValidationError on
      # purpose: unavailable means retry or fall back to asking the
      # human directly; malformed means the prompt is wrong, not the
      # transport, and retrying identically will not fix it.
      class Unavailable < StandardError
      end

      # ── what the four operations hand back ──────────────────────────
      #
      # Structs, not hashes, for the reason `Bluebook::ModelCheck::Finding`
      # already is one: a `keyword_init` Struct raises on a key nobody
      # declared, which turns "the model invented a field" into a
      # failure at the boundary rather than a nil three calls in.

      # One question. `because` is the reasoning quoted back so a human
      # can see it, not decoration — the same "show your work" the
      # language's own refusal messages already practice.
      Question = Struct.new(:text, :because, keyword_init: true)

      # One proposed declaration, already shaped as
      # `Interview::Proposal`'s own `Argument` rows — `{name:, field:,
      # value:}`, the exact triple `bin/interview propose --arg
      # name:field:value` already takes and `Interview::Lowering`
      # already knows how to lower. Nothing here decides how to address
      # a record or whether a value is bare or wrapped — that was
      # already the proposal-writer's job in `interview.bluebook`'s own
      # design (see `Argument`'s own comment there); this only adds the
      # prose reasoning a human typed does not carry on its own.
      Proposal = Struct.new(:verb, :arguments, :rationale, keyword_init: true)

      # Critique reuses `Bluebook::ModelCheck::Finding`'s own shape —
      # same fields, same severities, so a mechanical finding
      # (`Session#gaps`) and a judgement (this) print in one list and
      # sort together. The kind vocabulary is not shared — ModelCheck's
      # eleven kinds are structural facts about a graph; these are
      # opinions about a model, closed here on purpose (an open kind
      # field is an open prompt, and an open prompt drifts).
      CRITIQUE_KINDS = %i[
        anemic_aggregate wrong_boundary crud_verb leaky_value_object
        missing_lifecycle missing_invariant ubiquitous_language
        overreaching_identity untold_rule
      ].freeze
      SEVERITIES = %i[error warning].freeze

      Finding = Struct.new(:kind, :severity, :subject, :message, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{kind.to_s.ljust(20)} #{subject}  —  #{message}"
      end

      # One suggested name. `rejected` carries the near-misses and why
      # they were passed over — free at the point the model is choosing
      # anyway, and the part a human actually learns from.
      Suggestion = Struct.new(:name, :because, :rejected, keyword_init: true)

      module_function

      # Asks the adapter for the next best question and validates its raw answer into structs.
      #
      # `state` is the whole picture — normally
      # `Interview::Session#declaration` plus `#gaps`, so an adapter
      # needs no memory of its own between calls; that is what lets a
      # headless run be a series of one-shot processes, same as
      # `bin/interview` itself already is.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param state [Hash] the interview's whole current picture (declaration plus gaps),
      #   JSON-able because an adapter may serialise it into a prompt
      # @param asked [Array<Object>] JSON-able record of the questions already asked, so the
      #   adapter does not repeat one; `[]` when nothing has been asked
      # @return [Array<Ports::Agent::Question>] the questions the adapter answered with, in
      #   its order; `[]` if it offered none
      # @raise [Ports::Agent::ValidationError] if the answer is not a Hash holding a
      #   `"questions"` array whose rows each carry a non-blank `"text"` and `"because"`
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer at all (missing
      #   binary, failed subprocess, timeout, or an exhausted scripted queue)
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def ask(registry, state:, asked: [])
        Answers.questions(adapter(registry).ask(state: state, asked: asked))
      end

      # Turns a human's sentence into proposed declarations, validated into structs.
      #
      # Returns `[]` when the sentence
      # carried no declaration at all (a clarifying question back from
      # the human, say) — a legitimate answer, not a failure.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param prose [String] a human's plain-English sentence
      # @param state [Hash] the interview's whole current picture, JSON-able because an
      #   adapter may serialise it into a prompt
      # @return [Array<Ports::Agent::Proposal>] one proposal per declaration the sentence
      #   named; `[]` when it named none
      # @raise [Ports::Agent::ValidationError] if the answer is not a Hash holding a
      #   `"proposals"` array, a row's `"verb"` is not `Chapter::Aggregate.Command`, its
      #   `"rationale"` is blank, or one of its argument rows has no `"name"`
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer at all (missing
      #   binary, failed subprocess, timeout, or an exhausted scripted queue)
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def interpret(registry, prose:, state:)
        Answers.proposals(adapter(registry).interpret(prose: prose, state: state))
      end

      # Asks the adapter to judge a declared model on taste, validated into structs.
      #
      # What is wrong with this as a model — handed everything already
      # known (the language's own refusals, `Session#gaps`'s mechanical
      # findings) so it spends its judgement on what neither of those
      # can see, rather than restating them.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param declared [Hash] the chapter as declared so far, JSON-able because an adapter
      #   may serialise it into a prompt
      # @param refusals [Array<Object>] JSON-able refusals the language itself already
      #   raised; `[]` when there are none
      # @param findings [Array<Object>] JSON-able mechanical findings `Session#gaps` already
      #   found; `[]` when there are none
      # @return [Array<Ports::Agent::Finding>] the adapter's judgements; `[]` when it has
      #   nothing worth saying
      # @raise [Ports::Agent::ValidationError] if the answer is not a Hash holding a
      #   `"findings"` array, a row's `"kind"` is outside `CRITIQUE_KINDS`, its `"severity"`
      #   is outside `SEVERITIES`, or its `"subject"` or `"message"` is blank
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer at all (missing
      #   binary, failed subprocess, timeout, or an exhausted scripted queue)
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def critique(registry, declared:, refusals: [], findings: [])
        Answers.findings(adapter(registry).critique(declared: declared, refusals: refusals, findings: findings))
      end

      # Asks the adapter to suggest a name for a construct, validated into structs.
      #
      # Vocabulary help. `near` is what the chapter already calls
      # things, so a suggestion cannot collide with a name in use.
      #
      # Named `suggest_name`, not `name` — the plan's own word for this
      # operation, but `Module#name` already exists and is load-bearing
      # everywhere (backtraces, RSpec's own description building,
      # `inspect`): a module-function called `name` shadows it the
      # instant it's defined, and `SomeModule.name` (no args) then
      # raises `ArgumentError: missing keywords` the next time anything
      # — not this file, something else entirely — asks the module its
      # own name. Measured, not theoretical: this exact collision broke
      # RSpec's own failure-message formatting the first time it was
      # named `name` here.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param meaning [String] what the new name needs to mean
      # @param kind [String] the kind of construct being named, such as `"event"`; an
      #   adapter interpolates it into its prompt
      # @param near [Array<String>] names already in use in this chapter, which a suggestion
      #   must not collide with; `[]` when there are none
      # @return [Array<Ports::Agent::Suggestion>] the suggested names, each with its
      #   `rejected` near-misses as Strings
      # @raise [Ports::Agent::ValidationError] if the answer is not a Hash holding a
      #   `"names"` array whose rows each carry a non-blank `"name"` and `"because"`
      # @raise [Ports::Agent::Unavailable] if the adapter cannot answer at all (missing
      #   binary, failed subprocess, timeout, or an exhausted scripted queue)
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def suggest_name(registry, meaning:, kind:, near: [])
        Answers.suggestions(adapter(registry).suggest_name(meaning: meaning, kind: kind, near: near))
      end

      # Finds the single adapter bound to this port, refusing an ambiguous wiring.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Module] the adapter module or class implementing this port
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements this port,
      #   or the one that does has no Ruby implementation under `Hecks::Adapters`
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can conduct an interview"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end

require_relative "agent/answers"
