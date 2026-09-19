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

      # Critique reuses `Bluebook::ModelCheck::Finding`'S own shape —
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

      # One suggested NAME. `rejected` carries the near-misses and why
      # they were passed over — free at the point the model is choosing
      # anyway, and the part a human actually learns from.
      Suggestion = Struct.new(:name, :because, :rejected, keyword_init: true)

      module_function

      # The next best question. `state` is the whole picture — normally
      # `Interview::Session#declaration` plus `#gaps`, so an adapter
      # needs no memory of its own between calls; that is what lets a
      # headless run be a series of one-shot processes, same as
      # `bin/interview` itself already is.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param state [Object] the interview's whole current picture (declaration plus gaps)
      # @param asked [Array] questions already asked, so the adapter doesn't repeat itself
      # @return [Array<Question>]
      # @raise [ValidationError] if the adapter's answer doesn't parse into a Question
      # @raise [Unavailable] if the adapter cannot answer at all
      def ask(registry, state:, asked: [])
        Answers.questions(adapter(registry).ask(state: state, asked: asked))
      end

      # Prose -> proposed declarations. Returns `[]` when the sentence
      # carried no declaration at all (a clarifying question back from
      # the human, say) — a legitimate answer, not a failure.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param prose [String] a human's plain-English sentence
      # @param state [Object] the interview's whole current picture
      # @return [Array<Proposal>]
      # @raise [ValidationError] if the adapter's answer doesn't parse into Proposals
      # @raise [Unavailable] if the adapter cannot answer at all
      def interpret(registry, prose:, state:)
        Answers.proposals(adapter(registry).interpret(prose: prose, state: state))
      end

      # What is wrong with this as a model — handed everything already
      # known (the language's own refusals, `Session#gaps`'s mechanical
      # findings) so it spends its judgement on what neither of those
      # can see, rather than restating them.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param declared [Object] the chapter as declared so far
      # @param refusals [Array] refusals the language itself already raised
      # @param findings [Array] mechanical findings `Session#gaps` already found
      # @return [Array<Finding>]
      # @raise [ValidationError] if the adapter's answer doesn't parse into Findings
      # @raise [Unavailable] if the adapter cannot answer at all
      def critique(registry, declared:, refusals: [], findings: [])
        Answers.findings(adapter(registry).critique(declared: declared, refusals: refusals, findings: findings))
      end

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
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param meaning [String] what the new name needs to mean
      # @param kind [Symbol] the kind of construct being named
      # @param near [Array<String>] names already in use in this chapter, to avoid colliding with
      # @return [Array<Suggestion>]
      # @raise [ValidationError] if the adapter's answer doesn't parse into Suggestions
      # @raise [Unavailable] if the adapter cannot answer at all
      def suggest_name(registry, meaning:, kind:, near: [])
        Answers.suggestions(adapter(registry).suggest_name(meaning: meaning, kind: kind, near: near))
      end

      # Finds the single adapter bound to this port.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Class] the adapter class implementing this port
      # @raise [Runtime::WiringError] if zero or more than one adapter implements it
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
