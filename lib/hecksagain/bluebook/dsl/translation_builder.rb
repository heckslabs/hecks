require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class TranslationAggregateBuilder
        GRAMMAR_CONTEXT = "TranslationAggregate"

        include WordGate

        def initialize(name, was: nil)
          raise Malformed, "an aggregate translation needs a name" if name.to_s.empty?

          @name      = name
          @was       = was
          @renames   = {}
          @moves     = []
          @converts  = []
          @drops     = []
          @retypes   = []
          @computes  = []
          @rekeys    = []
          @backfills = []
        end

        def rename(old_name, to:)
          raise Malformed, "a rename needs a source name" if old_name.to_s.empty?
          raise Malformed, "a rename needs a destination name (to:)" if to.to_s.empty?

          @renames[old_name.to_sym] = to.to_sym
        end

        def move(old_path, to:)
          raise Malformed, "a move needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a move needs a source path" if old_path.to_s.empty?

          @moves << TranslationMove.new(old_path.to_s, to.to_s)
        end

        # A value with nothing structural in common with its replacement
        # — declared as an exhaustive table, not computed, so every value
        # that can appear in old data has a named destination. Paths
        # follow `move`'s convention: dotted reaches a value-object member.
        def convert(old_path, to:, values:)
          raise Malformed, "a convert needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a convert needs a source path" if old_path.to_s.empty?
          raise Malformed, "a convert needs a values: table" if values.nil? || values.empty?

          @converts << TranslationConvert.new(old_path.to_s, to.to_s, values)
        end

        # `drop` — item #13's full metaprogrammed dispatch, slice 2
        # (whole-project table-unification survey): a declared,
        # deliberate acknowledgment that an attribute's data does not
        # survive the rename — the honest alternative to letting it
        # vanish because nothing named it. A blank-guarded, kind-driven
        # coerce-and-append with nothing else, now executed by
        # `GenericDispatch`.

        # A value object's or entity's own type name changed, member
        # structure unchanged. The stored data never carries the type
        # name, so nothing moves — this declares that the pair of names
        # means the same shape, which is what lets the era diff accept it.
        def retype(old_type, to:)
          raise Malformed, "a retype needs a source type name" if old_type.to_s.empty?
          raise Malformed, "a retype needs a destination type name (to:)" if to.to_s.empty?

          @retypes << TranslationRetype.new(old_type.to_s, to.to_s)
        end

        # A computed transform whose only implementation is the SQL
        # expression itself — Postgres-only by construction. The scaffold
        # never proposes one; a human writes it, and the audit's
        # human-sampled review is its only verification.
        def compute(old_path, to:, sql:)
          raise Malformed, "a compute needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a compute needs a source path" if old_path.to_s.empty?
          raise Malformed, "a compute needs its sql: expression" if sql.to_s.empty?

          @computes << TranslationCompute.new(old_path.to_s, to.to_s, sql.to_s)
        end

        # THE AGGREGATE'S OWN IDENTITY, changing what it's computed from —
        # not a field crossing a boundary (`move`), not a value's own
        # transform (`compute`): the record's key. No path arguments,
        # unlike every rule above — nothing is consumed from or moved into
        # `state`, only what identifies the record is recomputed. Same
        # SQL-only, Postgres-only, human-reviewed-sample-is-the-only-
        # verification shape `compute` already has, and for the same
        # reason: there is nothing in-process to check this against.
        def rekey(sql:)
          raise Malformed, "a rekey needs its sql: expression" if sql.to_s.empty?

          @rekeys << TranslationRekey.new(sql.to_s)
        end

        # A NEWLY ADDED, required attribute — the addition-side sibling of
        # `drop`. Nothing to rename, move, or convert FROM, since old data
        # never held this field at all; `default` is what an existing
        # record reads until the next command against it writes a real
        # value. Adapter-agnostic, unlike `compute` — applied the same
        # in-process way rename/move/drop already are
        # (`Lineage#translate`), because there is nothing to compute here,
        # only a value to declare. This is what
        # `EraGuard.refuse_unsafe_addition!` asks for when a non-optional
        # attribute with no default: could leave an existing record with
        # the field genuinely absent.
        def backfill(name, default:)
          raise Malformed, "a backfill needs a name" if name.to_s.empty?
          raise Malformed, "a backfill needs a default: value" if default.nil?

          @backfills << TranslationBackfill.new(name.to_sym, default)
        end

        # The scaffold writes this where it cannot decide; a file carrying
        # one can only boot into this refusal — never a guess.
        #
        # RENAMED FROM `unresolved` — item #13's full metaprogrammed
        # dispatch (slice 4). Builds its own message with real branching
        # (empty vs. named candidates, a special :identity case), not a
        # fixed string a boolean `refuses:` flag could express — reached
        # through `calls:` instead, like `attribute`/`role`. NOT
        # bootstrap-reachable: translation.bluebook (loaded during
        # bootstrap, to describe the translation DSL itself) never
        # writes `unresolved` — that word is only ever used by real,
        # user-authored `.translation` files, loaded well after the
        # grammar table exists — so no BOOTSTRAP_CALLS_FALLBACK entry is
        # needed here (checked directly, not assumed).
        def unresolved_impl(name, candidates: [])
          raise Malformed, unresolved_message(name, candidates)
        end

        # `method_missing`/`respond_to_missing?` used to be hand-written
        # here, giving a hand-typed "must be rename, move, convert, ..."
        # list on every genuinely undefined call — WordGate (`include`d
        # above) now answers the same question off the self-hosted
        # grammar table instead, the exact "hardcoded legal-word list"
        # this whole arc's item #13 exists to close. A word admitted
        # elsewhere in the grammar but not in this context still gets a
        # richer, table-driven refusal than the old generic one did.

        def build
          TranslationAggregate.new(
            name: @name, was: @was, renames: @renames, moves: @moves, converts: @converts,
            drops: @drops, retypes: @retypes, computes: @computes, rekeys: @rekeys, backfills: @backfills
          )
        end

        private

        def unresolved_message(name, candidates)
          return identity_unresolved_message if name.to_sym == :identity

          rendered = Array(candidates).map { |candidate| render_path(candidate) }
          if rendered.empty?
            "#{@name}'s translation leaves #{render_path(name)} unresolved (no candidate matched — " \
              "consider drop, or compute on Postgres) — replace unresolved with a real rule before booting."
          else
            "#{@name}'s translation leaves #{render_path(name)} unresolved (candidates: #{rendered.join(', ')}) — " \
              "replace unresolved with a rename, move, convert, or drop before booting."
          end
        end

        def render_path(path)
          path.to_s.include?(".") ? path.to_s.inspect : ":#{path}"
        end

        # THE SCAFFOLD'S OWN HINT for the one drift it can detect but never
        # resolve on its own — an aggregate's `identified_by` changed. Not
        # a field to rename/move/drop, so none of the ordinary hints fit;
        # `coverage_check.rb#check_identity_unchanged!` is the real gate,
        # this only names the one rule that gets a legitimate mint through it.
        def identity_unresolved_message
          "#{@name}'s translation leaves its identity unresolved — identified_by changed since the held era. " \
            "Declare a rekey rule (a rename/move/drop cannot fix this) before booting."
        end
      end

      class TranslationBuilder
        GRAMMAR_CONTEXT = "Translation"

        include WordGate

        def initialize(domain, from:, to:)
          raise Malformed, "a translation names no domain" if domain.to_s.empty?
          raise Malformed, "#{domain}'s translation says nothing about its origin era (from:)" if from.to_s.empty?
          raise Malformed, "#{domain}'s translation says nothing about its destination era (to:)" if to.to_s.empty?

          @domain     = domain
          @from       = from
          @to         = to
          @aggregates = []
          @retired    = []
        end

        def aggregate(name, was: nil, &block)
          builder = TranslationAggregateBuilder.new(name, was: was)
          builder.instance_eval(&block) if block
          @aggregates << builder.build
        end

        # `retired` — item #13's full metaprogrammed dispatch, slice 2
        # (whole-project table-unification survey): an aggregate that is
        # gone outright — not renamed. The deliberate alternative to a
        # bogus `was:` claim on an unrelated aggregate. Same shape
        # `TranslationAggregateBuilder#drop` is, now executed by
        # `GenericDispatch`.

        # `method_missing`/`respond_to_missing?` — same removal as
        # TranslationAggregateBuilder's own, one level up: WordGate
        # (`include`d above) answers off the self-hosted grammar table
        # now instead of a hand-typed "it declares aggregate blocks and
        # retired aggregates" message.

        def build
          MetaValidator.call_translation(
            Translation.new(domain: @domain, from: @from, to: @to, aggregates: @aggregates, retired: @retired)
          )
        end

        def self.build(domain, from:, to:, &block)
          builder = new(domain, from: from, to: to)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
