require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses an `aggregate "Name" do ... end` block inside a `.translation`
      # file into a `TranslationAggregate` — the per-aggregate rules
      # (`rename`/`move`/`convert`/`retype`/`compute`/`rekey`/`backfill`/
      # `drop`) that carry one era's stored data forward to the next, plus
      # `unresolved` markers the scaffold writes wherever it cannot decide a
      # rule for itself.
      class TranslationAggregateBuilder
        GRAMMAR_CONTEXT = "TranslationAggregate".freeze

        include WordGate

        # @param name [String, Symbol] the aggregate's name in the destination era
        # @param was [String, Symbol, nil] the aggregate's earlier name, when renamed
        # @raise [Bluebook::DSL::Malformed] if `name` is empty
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

        # Declares a field rename with no other change: same path, new name.
        #
        # Answers the `rename` word (and, via the same table rows, its
        # siblings `move`/`convert`/`retype`/`compute`/`rekey`/`backfill`
        # below) through the table's `calls:` column — item #13's full
        # metaprogrammed dispatch (slice 4c). Each is carried in
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` like every other
        # `calls:`-routed word, but none of their rows are ever consulted
        # during real bootstrap: `translation.bluebook` describes its own
        # structure with aggregate/entity/attribute, never with these —
        # they're words for real, user-authored `.translation` files
        # only, loaded after the grammar table already exists.
        #
        # @param old_name [Symbol, String] the field's name in the held era
        # @param to [Symbol, String] the field's name in the destination era
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `old_name` or `to` is empty
        def rename_impl(old_name, to:)
          raise Malformed, "a rename needs a source name" if old_name.to_s.empty?
          raise Malformed, "a rename needs a destination name (to:)" if to.to_s.empty?

          @renames[old_name.to_sym] = to.to_sym
        end

        # Declares a field moved to a different path, name unchanged.
        #
        # @param old_path [String, Symbol] the field's path in the held era; dotted reaches a
        #   value-object member
        # @param to [String, Symbol] the field's path in the destination era
        # @return [Array<Bluebook::TranslationMove>] every move declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `old_path` or `to` is empty
        def move_impl(old_path, to:)
          raise Malformed, "a move needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a move needs a source path" if old_path.to_s.empty?

          @moves << TranslationMove.new(old_path.to_s, to.to_s)
        end

        # Declares an exhaustive value-to-value mapping for a field with nothing structural in
        # common with its replacement.
        #
        # A value with nothing structural in common with its replacement
        # — declared as an exhaustive table, not computed, so every value
        # that can appear in old data has a named destination. Paths
        # follow `move`'s convention: dotted reaches a value-object member.
        #
        # @param old_path [String, Symbol] the field's path in the held era
        # @param to [String, Symbol] the field's path in the destination era
        # @param values [Hash] every old value mapped to its destination value
        # @return [Array<Bluebook::TranslationConvert>] every convert declared so far, this one
        #   last
        # @raise [Bluebook::DSL::Malformed] if `old_path` or `to` is empty, or `values` is nil
        #   or empty
        def convert_impl(old_path, to:, values:)
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

        # Declares that a type's name changed while its member structure stayed the same.
        #
        # A value object's or entity's own type name changed, member
        # structure unchanged. The stored data never carries the type
        # name, so nothing moves — this declares that the pair of names
        # means the same shape, which is what lets the era diff accept it.
        #
        # @param old_type [String, Symbol] the type's name in the held era
        # @param to [String, Symbol] the type's name in the destination era
        # @return [Array<Bluebook::TranslationRetype>] every retype declared so far, this one
        #   last
        # @raise [Bluebook::DSL::Malformed] if `old_type` or `to` is empty
        def retype_impl(old_type, to:)
          raise Malformed, "a retype needs a source type name" if old_type.to_s.empty?
          raise Malformed, "a retype needs a destination type name (to:)" if to.to_s.empty?

          @retypes << TranslationRetype.new(old_type.to_s, to.to_s)
        end

        # Declares a field computed by a hand-written Postgres SQL expression.
        #
        # A computed transform whose only implementation is the SQL
        # expression itself — Postgres-only by construction. The scaffold
        # never proposes one; a human writes it, and the audit's
        # human-sampled review is its only verification.
        #
        # @param old_path [String, Symbol] the source field's path in the held era
        # @param to [String, Symbol] the field's path in the destination era
        # @param sql [String] the Postgres SQL expression computing the destination value
        # @return [Array<Bluebook::TranslationCompute>] every compute declared so far, this one
        #   last
        # @raise [Bluebook::DSL::Malformed] if `old_path`, `to`, or `sql` is empty
        def compute_impl(old_path, to:, sql:)
          raise Malformed, "a compute needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a compute needs a source path" if old_path.to_s.empty?
          raise Malformed, "a compute needs its sql: expression" if sql.to_s.empty?

          @computes << TranslationCompute.new(old_path.to_s, to.to_s, sql.to_s)
        end

        # Declares a hand-written Postgres SQL expression that recomputes the aggregate's own
        # identity.
        #
        # The aggregate's own identity, changing what it's computed from —
        # not a field crossing a boundary (`move`), not a value's own
        # transform (`compute`): the record's key. No path arguments,
        # unlike every rule above — nothing is consumed from or moved into
        # `state`, only what identifies the record is recomputed. Same
        # SQL-only, Postgres-only, human-reviewed-sample-is-the-only-
        # verification shape `compute` already has, and for the same
        # reason: there is nothing in-process to check this against.
        #
        # @param sql [String] the Postgres SQL expression computing the destination identity
        # @return [Array<Bluebook::TranslationRekey>] every rekey declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `sql` is empty
        def rekey_impl(sql:)
          raise Malformed, "a rekey needs its sql: expression" if sql.to_s.empty?

          @rekeys << TranslationRekey.new(sql.to_s)
        end

        # Declares a newly added, required attribute and the default existing records read
        # until a real value is written.
        #
        # A newly added, required attribute — the addition-side sibling of
        # `drop`. Nothing to rename, move, or convert from, since old data
        # never held this field at all; `default` is what an existing
        # record reads until the next command against it writes a real
        # value. Adapter-agnostic, unlike `compute` — applied the same
        # in-process way rename/move/drop already are
        # (`Lineage#translate`), because there is nothing to compute here,
        # only a value to declare. This is what
        # `EraGuard.refuse_unsafe_addition!` asks for when a non-optional
        # attribute with no default: could leave an existing record with
        # the field genuinely absent.
        #
        # @param name [String, Symbol] the new attribute's name
        # @param default [Object] the value an existing record reads until it is written for real
        # @return [Array<Bluebook::TranslationBackfill>] every backfill declared so far, this
        #   one last
        # @raise [Bluebook::DSL::Malformed] if `name` is empty or `default` is nil
        def backfill_impl(name, default:)
          raise Malformed, "a backfill needs a name" if name.to_s.empty?
          raise Malformed, "a backfill needs a default: value" if default.nil?

          @backfills << TranslationBackfill.new(name.to_sym, default)
        end

        # Always refuses to boot: marks a field the scaffold could not decide a rule for.
        #
        # The scaffold writes this where it cannot decide; a file carrying
        # one can only boot into this refusal — never a guess.
        #
        # Answers the `unresolved` word through the table's `calls:`
        # column — item #13's full metaprogrammed
        # dispatch (slice 4). Builds its own message with real branching
        # (empty vs. named candidates, a special :identity case), not a
        # fixed string a boolean `refuses:` flag could express. Carried in
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` like every other
        # `calls:`-routed word, but that row is never consulted during
        # real bootstrap (checked directly, not assumed):
        # translation.bluebook (loaded during bootstrap, to describe the
        # translation DSL itself) never writes `unresolved` — that word is
        # only ever used by real, user-authored `.translation` files,
        # loaded well after the grammar table already exists.
        #
        # @param name [String, Symbol] the unresolved field's name, or `:identity` for an
        #   unresolved identity change
        # @param candidates [Array<String, Symbol>] paths the scaffold considered but could not
        #   choose between; empty when it found none
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] always
        def unresolved_impl(name, candidates: [])
          raise Malformed, unresolved_message(name, candidates)
        end

        # `method_missing`/`respond_to_missing?` answer off the self-hosted
        # grammar table (via the `include`d `WordGate`, above), giving a
        # richer, table-driven "must be rename, move, convert, ..." refusal
        # on a genuinely undefined call than a hand-typed list could —
        # the exact "hardcoded legal-word list" this whole arc's item #13
        # exists to close. A word admitted
        # elsewhere in the grammar but not in this context still gets that
        # richer refusal.

        # Assembles the declared rules into a `TranslationAggregate`.
        #
        # @return [Bluebook::TranslationAggregate] the built per-aggregate translation
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

        # The scaffold's own hint for the one drift it can detect but never
        # resolve on its own — an aggregate's `identified_by` changed. Not
        # a field to rename/move/drop, so none of the ordinary hints fit;
        # `coverage_check.rb#check_identity_unchanged!` is the real gate,
        # this only names the one rule that gets a legitimate mint through it.
        def identity_unresolved_message
          "#{@name}'s translation leaves its identity unresolved — identified_by changed since the held era. " \
            "Declare a rekey rule (a rename/move/drop cannot fix this) before booting."
        end
      end

      # Parses a whole `.translation` file into a `Translation` — the
      # domain's own `from:`/`to:` era pair, its list of `aggregate`
      # translation blocks (each built by `TranslationAggregateBuilder`
      # above), and any `retired` aggregates that no longer exist in the
      # destination era.
      class TranslationBuilder
        GRAMMAR_CONTEXT = "Translation".freeze

        include WordGate

        # @param domain [String, Symbol] the domain this translation carries forward
        # @param from [String, Symbol] the origin era
        # @param to [String, Symbol] the destination era
        # @raise [Bluebook::DSL::Malformed] if `domain`, `from`, or `to` is empty
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

        # Declares one aggregate's own translation rules.
        #
        # Answers the `aggregate` word through the table's `calls:`
        # column — item #13's full metaprogrammed
        # dispatch (slice 4c). Not bootstrap-reachable — this "Translation"
        # -context `aggregate` (opens a TranslationAggregateBuilder) is a
        # different (context, word) pair than "Bluebook"-context
        # `aggregate` (the one translation.bluebook itself is described
        # with), so it never describes the language's own
        # translation chapter.
        #
        # @param name [String, Symbol] the aggregate's name in the destination era
        # @param was [String, Symbol, nil] the aggregate's earlier name, when renamed
        # @yield the aggregate's own translation body, evaluated against a
        #   `TranslationAggregateBuilder`
        # @return [Array<Bluebook::TranslationAggregate>] every aggregate translation declared
        #   so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `name` is empty, or any rule in the body fails
        #   its own checks
        def aggregate_impl(name, was: nil, &block)
          builder = TranslationAggregateBuilder.new(name, was: was)
          builder.instance_eval(&block) if block
          @aggregates << builder.build
        end

        # `retired` (an aggregate that is gone outright, not renamed — the
        # deliberate alternative to a bogus `was:` claim on an unrelated
        # aggregate, the same shape `TranslationAggregateBuilder#drop` is)
        # is executed straight off the grammar table by `GenericDispatch` —
        # item #13's full metaprogrammed dispatch, slice 2 (whole-project
        # table-unification survey) — so no hand-written method answers it here.

        # `method_missing`/`respond_to_missing?` answer off the self-hosted
        # grammar table (via the `include`d `WordGate`, above, the same
        # mechanism `TranslationAggregateBuilder`'s own comment describes
        # one level up) instead of a hand-typed "it declares aggregate
        # blocks and retired aggregates" message.

        # Assembles the declared era pair, aggregates and retirements, judged by the translation
        # language.
        #
        # @return [Bluebook::Translation] the translation, returned once the language accepts it
        # @raise [Bluebook::DSL::Malformed] if the translation language refuses the declaration
        def build
          MetaValidator.call_translation(
            Translation.new(domain: @domain, from: @from, to: @to, aggregates: @aggregates, retired: @retired)
          )
        end

        # Evaluates a `.translation` file's top-level block against a fresh builder.
        #
        # @param domain [String, Symbol] the domain this translation carries forward
        # @param from [String, Symbol] the origin era
        # @param to [String, Symbol] the destination era
        # @yield the translation body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Translation] the judged translation
        # @raise [Bluebook::DSL::Malformed] if the body fails any check, or the translation
        #   language refuses the declaration
        def self.build(domain, from:, to:, &block)
          builder = new(domain, from: from, to: to)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
