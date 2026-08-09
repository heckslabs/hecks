module Hecksagain
  module Bluebook
    module DSL
      class TranslationAggregateBuilder
        def initialize(name, was: nil)
          raise Malformed, "an aggregate translation needs a name" if name.to_s.empty?

          @name     = name
          @was      = was
          @renames  = {}
          @moves    = []
          @converts = []
          @drops    = []
          @retypes  = []
          @computes = []
          @rekeys   = []
        end

        def rename(old_name, to:)
          raise Malformed, "a rename needs a source name" if old_name.to_s.empty?
          raise Malformed, "a rename needs a destination name (to:)" if to.to_s.empty?

          @renames[old_name.to_sym] = to.to_sym
        end

        def move(old_path, to:)
          raise Malformed, "a move needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a move needs a source path" if old_path.to_s.empty?

          @moves << IR::TranslationMove.new(old_path.to_s, to.to_s)
        end

        # A value with nothing structural in common with its replacement
        # — declared as an exhaustive table, not computed, so every value
        # that can appear in old data has a named destination. Paths
        # follow `move`'s convention: dotted reaches a value-object member.
        def convert(old_path, to:, values:)
          raise Malformed, "a convert needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a convert needs a source path" if old_path.to_s.empty?
          raise Malformed, "a convert needs a values: table" if values.nil? || values.empty?

          @converts << IR::TranslationConvert.new(old_path.to_s, to.to_s, values)
        end

        # A declared, deliberate acknowledgment that an attribute's data
        # does not survive the rename — the honest alternative to letting
        # it vanish because nothing named it.
        def drop(name)
          raise Malformed, "a drop needs a name" if name.to_s.empty?

          @drops << name.to_sym
        end

        # A value object's or entity's own type name changed, member
        # structure unchanged. The stored data never carries the type
        # name, so nothing moves — this declares that the pair of names
        # means the same shape, which is what lets the era diff accept it.
        def retype(old_type, to:)
          raise Malformed, "a retype needs a source type name" if old_type.to_s.empty?
          raise Malformed, "a retype needs a destination type name (to:)" if to.to_s.empty?

          @retypes << IR::TranslationRetype.new(old_type.to_s, to.to_s)
        end

        # A computed transform whose only implementation is the SQL
        # expression itself — Postgres-only by construction. The scaffold
        # never proposes one; a human writes it, and the audit's
        # human-sampled review is its only verification.
        def compute(old_path, to:, sql:)
          raise Malformed, "a compute needs a destination path (to:)" if to.to_s.empty?
          raise Malformed, "a compute needs a source path" if old_path.to_s.empty?
          raise Malformed, "a compute needs its sql: expression" if sql.to_s.empty?

          @computes << IR::TranslationCompute.new(old_path.to_s, to.to_s, sql.to_s)
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

          @rekeys << IR::TranslationRekey.new(sql.to_s)
        end

        # The scaffold writes this where it cannot decide; a file carrying
        # one can only boot into this refusal — never a guess.
        def unresolved(name, candidates: [])
          raise Malformed, unresolved_message(name, candidates)
        end

        def method_missing(rule, *_args, **_kwargs, &_block)
          raise Malformed,
                "a translation rule must be rename, move, convert, drop, retype, compute, rekey, or unresolved — " \
                "got '#{rule}'"
        end

        private def respond_to_missing?(_name, _include_private = false) = true

        def build
          IR::TranslationAggregate.new(
            name: @name, was: @was, renames: @renames, moves: @moves, converts: @converts,
            drops: @drops, retypes: @retypes, computes: @computes, rekeys: @rekeys
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

        # An aggregate that is gone outright — not renamed. The deliberate
        # alternative to a bogus `was:` claim on an unrelated aggregate.
        def retired(name)
          raise Malformed, "a retired needs an aggregate name" if name.to_s.empty?

          @retired << name.to_s
        end

        def method_missing(name, *_args, **_kwargs, &_block)
          raise Malformed,
                "a translation does not understand '#{name}' — it declares aggregate blocks and retired aggregates"
        end

        private def respond_to_missing?(_name, _include_private = false) = true

        def build = IR::Translation.new(domain: @domain, from: @from, to: @to, aggregates: @aggregates, retired: @retired)

        def self.build(domain, from:, to:, &block)
          builder = new(domain, from: from, to: to)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
