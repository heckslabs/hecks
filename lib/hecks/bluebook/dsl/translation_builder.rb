require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses an `aggregate "Name" do ... end` block in a `.translation` file into a
      # `TranslationAggregate`: the rules that carry one era's stored data to the next.
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
        # @param old_path [String, Symbol] the field's path in the held era; dotted reaches a
        #   value-object member
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

        # `drop` (attribute data that does not survive the rename) is dispatched directly off
        # the grammar table by `GenericDispatch`; no method answers it here.

        # Declares that a type's name changed while its member structure stayed the same.
        #
        # Nothing moves: stored data never carries the type name, so this only tells the era
        # diff that the two names mean the same shape.
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
        # The scaffold never proposes one; a human writes it, and human-sampled review is
        # its only verification.
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
        # No path arguments, unlike the rules above: only the record's key is recomputed, not
        # state moved into it. Verified the same human-reviewed-only way as `compute`.
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
        # What `EraGuard.refuse_unsafe_addition!` requires before a non-optional attribute
        # with no default can boot.
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
        # @param name [String, Symbol] the unresolved field's name, or `:identity` for an
        #   unresolved identity change
        # @param candidates [Array<String, Symbol>] paths the scaffold considered but could not
        #   choose between; empty when it found none
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] always
        def unresolved_impl(name, candidates: [])
          raise Malformed, unresolved_message(name, candidates)
        end

        # `method_missing`/`respond_to_missing?` (via the included `WordGate`) give a
        # table-driven refusal naming the legal words, rather than a hand-typed list.

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

      # Parses a whole `.translation` file into a `Translation`: the domain's `from:`/`to:`
      # era pair, its `aggregate` blocks, and any `retired` aggregates.
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

        # Declares one aggregate's own translation rules; a distinct (context, word) pair
        # from "Bluebook"-context `aggregate`, despite sharing the word.
        #
        # @param name [String, Symbol] the aggregate's name in the destination era
        # @param was [String, Symbol, nil] the aggregate's earlier name, when renamed
        # @yield the translation body, evaluated against a `TranslationAggregateBuilder`
        # @return [Array<Bluebook::TranslationAggregate>] every declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `name` is empty, or a body rule fails its own checks
        def aggregate_impl(name, was: nil, &block)
          builder = TranslationAggregateBuilder.new(name, was: was)
          builder.instance_eval(&block) if block
          @aggregates << builder.build
        end

        # `retired` (an aggregate gone outright, not renamed) is dispatched straight off the
        # grammar table by `GenericDispatch`; no method answers it here.

        # `method_missing`/`respond_to_missing?` (via the included `WordGate`) give the same
        # table-driven refusal `TranslationAggregateBuilder` uses.

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
