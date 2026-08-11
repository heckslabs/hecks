require_relative "../bluebook/meta_validator"
require_relative "../bluebook/meta_validator/plan"
# READINGS AND SHAPES BEFORE RECONSTRUCTION, on purpose — `Reconstruction`
# does `include Readings` and `include Shapes` but requires neither itself
# (nor does `judge.rb`, which needs `Readings` for the identical reason);
# the whole chapter only ever loads correctly because
# `lib/hecksagain/bluebook.rb`'s own require list happens to load every
# sibling in the right order. This file does not go through `bluebook.rb`
# — `spec/load_hygiene_spec.rb` caught this standalone (`require
# "hecksagain/interview/session"` alone raised, first on
# `Reconstruction::Readings`, then on `Reconstruction::Shapes` once the
# first was fixed) — so the order has to be restated here rather than
# assumed.
require_relative "../bluebook/meta_validator/readings"
require_relative "../bluebook/meta_validator/shapes"
require_relative "../bluebook/meta_validator/reconstruction"
require_relative "../bluebook/assembly"
require_relative "../bluebook/model_check"
require_relative "../runtime/registry"
require_relative "../runtime/dispatcher"
require_relative "../naming"

module Hecksagain
  module Interview
    # A DOMAIN BEING BUILT, HELD AS RECORDS RATHER THAN AS TEXT.
    #
    # The partial bluebook lives in its own meta-domain store, one
    # declaration at a time, and the language's REFUSALS are the
    # interview's feedback — not a rule this class knows, but
    # `Runtime::NotFound` or `Runtime::GivenNotMet` coming back from a real
    # dispatch, in the language's own words, naming the exact thing that is
    # missing or wrong.
    #
    # NOT `MetaValidator.fresh_runtime`. That clears the MEMOISED grammar
    # registry's own repositories — measured, not assumed: booting any
    # OTHER domain anywhere in the same process (a spec, a `Hecks.boot`)
    # wipes every record a Session holds, mid-interview, because
    # `fresh_runtime` is the singleton `MetaValidator.grammar_registry`
    # with `@repositories` reset in place. `MetaValidator.load_grammar_into`
    # on a registry THIS CLASS OWNS is what its own header already invites
    # ("anything that needs an ISOLATED registry ... calls this directly"),
    # and an isolated session survives a full `Hecks.boot` elsewhere in the
    # process untouched.
    #
    # THE PLAN COMES FROM THE SINGLETON ANYWAY, and that asymmetry is
    # deliberate: `Plan` reads the language's SHAPE — which verb appends to
    # which list, which argument carries a reference — and that shape is
    # identical in both registries. Records are isolated; the language they
    # are read against is shared, the same way two aggregates in one real
    # domain share one language without needing two copies of it.
    #
    # NEVER `bind_runtime`. `MetaValidator` itself deliberately never does
    # this — installing `Bluebook::Aggregate` and friends as global facade
    # constants once per judged chapter would collide with the real
    # `Interview::Interview`/`Interview::Finding` door this domain's OWN
    # chapter installs. The meta-domain stays dispatch-driven, which it
    # has to be anyway: its verbs are computed from `Plan`, not written as
    # source, so they are strings by nature.
    class Session
      attr_reader :chapter, :runtime, :plan, :pending

      def self.open(chapter) = new(chapter)

      def initialize(chapter)
        @chapter = chapter.to_s
        registry = Bluebook::MetaValidator.load_grammar_into(Runtime::Registry.new)
        @runtime = Runtime::Dispatcher.new(registry)
        @plan    = Bluebook::MetaValidator::Plan.for(Bluebook::MetaValidator.grammar_registry)
        @pending = []
        # THE ONE DISPATCH EVERY SESSION OPENS WITH. `Reconstruction.of`
        # raises `NotFound` without a Bluebook row to read back — this is
        # what makes "not sealed yet" the language's own word for an
        # in-progress model instead of a special case this class invents.
        #
        # NO `id:` — `Bluebook.Declare` derives its identity from `name`
        # alone (`identity_heads == [:name]`), the same way every other
        # creating command in this language does. `:id` is accepted on
        # ANY dispatch (`ArgumentGate#refuse_unknown_arguments` always
        # tolerates it, alongside the real identity heads, as one of the
        # keys that ADDRESS a record rather than describe it) but a
        # creating command never reads its value — passing one here would
        # be decoration a future reader could mistake for meaning.
        dispatch("Bluebook::Bluebook.Declare", name: { value: @chapter })
      end

      # ── the one operation that matters ─────────────────────────────────

      # ONE DECLARATION, OFFERED. The verdict is either acceptance or the
      # language's own sentence about why not.
      def offer(verb, **args)
        dispatch(verb, **args)
        drain!
        Verdict.new(verb: verb, args: args, accepted: true)
      rescue Runtime::NotFound => e
        # NOT FOUND IS A PREREQUISITE, NOT A DEFEAT — every NotFound this
        # runtime can raise while BUILDING a declaration (as opposed to
        # judging a finished one) names a record that has not been
        # declared YET: an attribute's type pointing at an undeclared
        # value object, a reference to an aggregate not yet identified.
        # The message names the exact missing id, so the proposal is
        # parked and re-offered after any later dispatch that could
        # satisfy it — a human interviewed out of dependency order should
        # not have to already know the language's own declaration order.
        @pending << PendingDispatch.new(verb: verb, args: args)
        Verdict.new(verb: verb, args: args, accepted: false, refusal: e.message, wants: :prerequisite)
      rescue *(Runtime::DOMAIN_REFUSALS - [Runtime::NotFound]) => e
        # DERIVED FROM THE LANGUAGE'S OWN LIST, not hand-copied — the same
        # discipline `DOMAIN_REFUSALS` itself exists to hold (see
        # runtime/errors.rb's own history: InvariantViolation was once
        # missing from it, and every refusal it raised propagated as
        # though the RUNTIME had broken rather than the domain saying no).
        # Extending that list teaches this rescue automatically.
        #
        # UnknownVerb IS NOT PARKED, where `MetaValidator::Judge` tolerates
        # it — Judge is walking a WHOLE document and a verb the language
        # does not offer there is a category mismatch, harmless to skip.
        # An interview offering ONE declaration at a time that names no
        # such verb is a real mistake, and retrying it later would never
        # resolve: nothing about a LATER dispatch could make an unknown
        # verb known.
        Verdict.new(verb: verb, args: args, accepted: false, refusal: e.message, wants: wants_of(e))
      end

      # A LEAST FIXPOINT OVER THE PARKED DECLARATIONS — the same shape
      # `ModelCheck#reachable_states` already uses for an unrelated reason:
      # keep re-attempting while anything moved, stop the moment nothing
      # does. Only ever grows the model; a parked declaration that still
      # refuses stays parked rather than being dropped.
      def drain!
        loop do
          moved = false
          @pending.dup.each do |parked|
            dispatch(parked.verb, **parked.args)
            @pending.delete(parked)
            moved = true
          rescue *Runtime::DOMAIN_REFUSALS
            nil # still waiting on something else, or still wrong — either way, stays parked
          end
          break unless moved
        end
      end

      # ── reading it back ──────────────────────────────────────────────

      # THE PARTIAL BLUEBOOK, AS IR. Verified to work mid-interview on an
      # unsealed chapter: an aggregate with no `Identify` comes back with
      # `identified_by: []` rather than raising, and `Assembly` accepts
      # that. Needs the chapter row, which is why `initialize` dispatches
      # `Bluebook.Declare` before anything else.
      def declaration = Bluebook::MetaValidator::Reconstruction.of(@runtime, @chapter)

      def assembled = Bluebook::Assembly.call(declaration)

      # ── what is missing right now ──────────────────────────────────────

      # THREE SOURCES, CHEAPEST AND TRUEST FIRST.
      def gaps = seal_gaps + check_gaps

      # THE LANGUAGE NAMES ITS OWN GAPS. Every sealer in the plan is a
      # command with NO mutations (`Plan::Category#sealers`) — dispatching
      # one changes nothing and can be repeated forever. So this simply
      # offers every sealer for every record it holds and collects the
      # refusals, each phrased by the language rather than by this file.
      # This is the whole reason "not sealed yet" is the right
      # representation of an interview in progress.
      def seal_gaps
        @plan.names.flat_map do |category|
          held = @plan.category(category)
          next [] if held.sealers.empty?

          ids_of(category).flat_map do |id|
            held.sealers.filter_map { |verb| seal_gap_for(category, verb, id) }
          end
        end
      end

      # STATIC ANALYSIS OVER THE PARTIAL GRAPH. Rescued: `ModelCheck` was
      # written for a COMPLETE chapter, and a half-built one can hand it a
      # lifecycle whose transitions name commands that do not exist yet —
      # correctly reported, and noise mid-interview rather than a finding.
      def check_gaps
        Bluebook::ModelCheck.call(assembled).map do |finding|
          Gap.new(kind: finding.kind, subject: finding.subject, message: finding.message,
                  source: :model_check, severity: finding.severity)
        end
      rescue StandardError => e
        [Gap.new(kind: :uncheckable, subject: @chapter, source: :model_check, severity: :warning,
                 message: "the model is not yet whole enough to check: #{e.message}")]
      end

      # EVERY RECORD OF A CATEGORY, AS JOINED IDS — never as separate
      # identity-head arguments. Measured, not guessed: several of the
      # language's own appender verbs (`Aggregate.Attribute`,
      # `.Reference`, `.Holds`, `.Value`) declare an argument of their own
      # ALSO called `name` — the exact field `identity_heads` reads to
      # address WHICH aggregate. Passing `bluebook_id:`/`name:` together
      # resolves the address correctly (`Identity.of` is tried first) but
      # the *same* `name:` value is then read a second time as the new
      # attribute's own field, silently misnaming it. `id:` is the one
      # addressing key ArgumentGate always tolerates and no command ever
      # declares as its own payload field — the single channel with no
      # collision, which is why every dispatch in this file goes through
      # it rather than the (individually correct, jointly ambiguous)
      # identity-head names.
      def ids_of(category)
        held = @plan.category(category)
        return [@chapter] unless held.parent_key

        parents_of(category).flat_map do |parent|
          @runtime.query("Bluebook::#{category}.DeclaredIn", held.parent_key.to_sym => { value: parent })
                  .map { |row| row[:id].to_s }
        end
      rescue Runtime::UnknownVerb
        []
      end

      private

      # A CATEGORY'S PARENTS ARE ITS OWN PARENT CATEGORY'S RECORDS — walked
      # up one level at a time until the root, the same recursion
      # `MetaValidator::Judge`'s own tree-shaped walk performs top-down.
      # Read here bottom-up because `ids_of` needs "which parents exist"
      # before it can ask "what was declared under each one".
      def parents_of(category)
        held = @plan.category(category)
        return [@chapter] unless held.parent

        ids_of(held.parent)
      end

      def seal_gap_for(category, verb, id)
        @runtime.dispatch("Bluebook::#{category}.#{verb}", id: id)
        nil
      rescue Runtime::GivenNotMet, Runtime::InvariantViolation => e
        Gap.new(kind: :unsealed, subject: "#{category}##{id}", message: e.message,
                source: :seal, severity: :error)
      end

      def dispatch(verb, **args) = @runtime.dispatch(verb, **args)

      def wants_of(error)
        case error
        when Runtime::AlreadyExists then :already_said
        when Runtime::UnknownVerb   then :no_such_construct
        else :rule
        end
      end

      PendingDispatch = Struct.new(:verb, :args, keyword_init: true)

      Verdict = Struct.new(:verb, :args, :accepted, :refusal, :wants, keyword_init: true) do
        def accepted? = !!accepted
        def to_s = accepted? ? "ACCEPTED  #{verb}" : "REFUSED   #{verb}\n          #{refusal}"
      end

      # SHAPED SO A ModelCheck::Finding CONVERTS 1:1 — one list, one sort,
      # one thing for a reader to walk.
      Gap = Struct.new(:kind, :subject, :message, :source, :severity, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{source.to_s.ljust(12)} #{kind.to_s.ljust(20)} " \
                   "#{subject}  —  #{message}"
      end
    end
  end
end
