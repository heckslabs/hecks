require_relative "../runtime/registry"

module Hecksagain
  module Ports
    # THE INTERVIEWER — whatever asks the next good question, reads a
    # sentence back into proposed declarations, judges a model on taste
    # rather than structure, or suggests a name. Resolved the singleton
    # way every other port here is (`Ports::IdentityGeneration`'s own
    # zero/one/many — one interviewer per process, never per-aggregate),
    # because a second adapter answering this port is exactly as
    # unchoosable as a second one minting identities.
    #
    # BUILT LAST, ON PURPOSE, AND STILL OPTIONAL. `.claude/skills/
    # interview/SKILL.md` conducts a whole session with NONE of this —
    # Claude Code reads `bin/interview state` itself, asks the human
    # directly with real conversation context, and calls `bin/interview
    # ask`/`propose`/`accept` itself. This port exists for what that
    # cannot reach: a HEADLESS run (`bin/interview suggest`, no model in
    # the room otherwise), a batch `critique` over an already-written
    # chapter, and — the actual point of building it at all — a
    # SCRIPTED double (`spec/fixtures/scripted_agent.rb`) that makes the
    # whole loop testable with no real model involved.
    #
    # WHAT THIS PORT IS NOT. It does not judge whether a declaration is
    # WELL-FORMED — that is the meta-domain's own job, answered by a real
    # dispatch refusing or not (`Interview::Session#offer`). This port
    # only ever produces SHAPE: a question, a proposed declaration, a
    # judgement about taste, a name. A proposal naming a category the
    # language does not declare is an ADAPTER fault, refused HERE, in
    # `Answers`; a proposal naming a real category but describing the
    # wrong domain fact is dispatched anyway, so the LANGUAGE gets to say
    # why. That line is the whole design.
    #
    # PARSING BELONGS TO THIS FILE, NOT THE ADAPTER. An adapter answers
    # with a plain, already-JSON-shaped Hash (a real model's parsed
    # reply, or a spec double's own hand-built one) — never a Struct —
    # so every adapter is validated identically here rather than trusting
    # each one to refuse the same way. Two adapters that parsed
    # differently would mean the SAME malformed answer passing through
    # one and refusing through the other.
    module Agent
      NAME = "agent"

      # The answer came back and could not be used — no JSON in it, a
      # category the language does not declare, a severity outside the
      # two that exist. A foreign failure (JSON::ParserError, a missing
      # key) wrapped into something this port owns, the same shape
      # `Ports::Authentication::ValidationError` already is, so no
      # caller ever rescues a raw parser error leaking out of an
      # adapter.
      ValidationError = Class.new(StandardError)

      # Nothing answered at all — the binary is missing, the subprocess
      # died, the call timed out. Separate from ValidationError on
      # purpose: unavailable means retry or fall back to asking the
      # human directly; malformed means the PROMPT is wrong, not the
      # transport, and retrying identically will not fix it.
      Unavailable = Class.new(StandardError)

      # ── what the four operations hand back ──────────────────────────
      #
      # Structs, not hashes, for the reason `Bluebook::ModelCheck::Finding`
      # already is one: a `keyword_init` Struct raises on a key nobody
      # declared, which turns "the model invented a field" into a
      # failure at the boundary rather than a nil three calls in.

      # ONE QUESTION. `because` is the reasoning quoted back so a human
      # can see it, not decoration — the same "show your work" the
      # language's own refusal messages already practice.
      Question = Struct.new(:text, :because, keyword_init: true)

      # ONE PROPOSED DECLARATION, already shaped as
      # `Interview::Proposal`'s own `Argument` rows — `{name:, field:,
      # value:}`, the exact triple `bin/interview propose --arg
      # name:field:value` already takes and `Interview::Lowering`
      # already knows how to lower. Nothing here decides HOW to address
      # a record or whether a value is bare or wrapped — that was
      # already the proposal-writer's job in `interview.bluebook`'s own
      # design (see `Argument`'s own comment there); this only adds the
      # PROSE reasoning a human typed does not carry on its own.
      Proposal = Struct.new(:verb, :arguments, :rationale, keyword_init: true)

      # CRITIQUE REUSES `Bluebook::ModelCheck::Finding`'S OWN SHAPE —
      # same fields, same severities, so a mechanical finding
      # (`Session#gaps`) and a judgement (this) print in one list and
      # sort together. The KIND vocabulary is NOT shared — ModelCheck's
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

      # ONE SUGGESTED NAME. `rejected` carries the near-misses and why
      # they were passed over — free at the point the model is choosing
      # anyway, and the part a human actually learns from.
      Suggestion = Struct.new(:name, :because, :rejected, keyword_init: true)

      module_function

      # THE NEXT BEST QUESTION. `state` is the whole picture — normally
      # `Interview::Session#declaration` plus `#gaps`, so an adapter
      # needs no memory of its own between calls; that is what lets a
      # headless run be a series of one-shot processes, same as
      # `bin/interview` itself already is.
      def ask(registry, state:, asked: [])
        Answers.questions(adapter(registry).ask(state: state, asked: asked))
      end

      # PROSE -> PROPOSED DECLARATIONS. Returns `[]` when the sentence
      # carried no declaration at all (a clarifying question back from
      # the human, say) — a legitimate answer, not a failure.
      def interpret(registry, prose:, state:)
        Answers.proposals(adapter(registry).interpret(prose: prose, state: state))
      end

      # WHAT IS WRONG WITH THIS AS A MODEL — handed everything already
      # known (the language's own refusals, `Session#gaps`'s mechanical
      # findings) so it spends its judgement on what neither of those
      # can see, rather than restating them.
      def critique(registry, declared:, refusals: [], findings: [])
        Answers.findings(adapter(registry).critique(declared: declared, refusals: refusals, findings: findings))
      end

      # VOCABULARY HELP. `near` is what the chapter already calls
      # things, so a suggestion cannot collide with a name in use.
      #
      # NAMED `suggest_name`, NOT `name` — the plan's own word for this
      # operation, but `Module#name` already exists and is load-bearing
      # everywhere (backtraces, RSpec's own description building,
      # `inspect`): a module-function called `name` SHADOWS it the
      # instant it's defined, and `SomeModule.name` (no args) then
      # raises `ArgumentError: missing keywords` the next time anything
      # — not this file, something else entirely — asks the module its
      # own name. Measured, not theoretical: this exact collision broke
      # RSpec's own failure-message formatting the first time it was
      # named `name` here.
      def suggest_name(registry, meaning:, kind:, near: [])
        Answers.suggestions(adapter(registry).suggest_name(meaning: meaning, kind: kind, near: near))
      end

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name)
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
