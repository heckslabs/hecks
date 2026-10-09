module Hecks
  module Bluebook
    module DSL
      # The effect words of a command: `sets`, its frozen-era spelling `then_set`,
      # `delegates_to` and `corrects`, each recording one `Mutation`.
      class CommandBuilder
        # Maps each `sets` kwarg to the mutation op it selects. `to:` is the one kwarg
        # whose own name differs from the op it selects (`:set`); every other kwarg
        # selects the op of its own name.
        KWARG_TO_OP = { to: :set, append: :append, increment: :increment, decrement: :decrement,
                        multiply: :multiply, clamp: :clamp, remove: :remove }.freeze

        # The effects that write a field of the record — `delegate` and
        # `corrects` name a command and an event, never a field.
        FIELD_EFFECTS = %i[set append remove increment decrement multiply clamp].freeze

        # Declares one mutation this command applies to `target`, its op selected by
        # whichever single keyword names a source; omitting all of them means `to: target`.
        #
        # @param target [Symbol, String] the field the mutation writes
        # @param positional_to [Object] the source, written without `to:`
        # @param ops [Hash] at most one of `to:`, `append:`, `increment:`, `decrement:`,
        #   `multiply:`, `clamp:` (the `[min, max]` pair to bound the current value to),
        #   `remove:`; a Symbol `to:` equal to `target` is redundant and refused
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `to:` redundantly repeats `target`, or more than
        #   one op-selecting keyword is given
        # @raise [ArgumentError] on any other keyword
        def sets_impl(target, positional_to = UNSET, **ops)
          refuse_unknown_ops!(ops, KWARG_TO_OP.keys)
          ops = source_of_to(ops, positional_to)

          # Only a Symbol can repeat the target's name; a literal value (`to: false`,
          # a String, ...) never has `.to_sym` to compare in the first place.
          refuse_repeated_target!(target, ops[:to])

          named = KWARG_TO_OP.keys.select { |kwarg| ops.key?(kwarg) }.to_h { |kwarg| [KWARG_TO_OP[kwarg], ops[kwarg]] }

          # No operation named at all (not even bare `to:`) means `sets :field` alone.
          record_mutation("sets", target, named.empty? ? { set: target } : named)
        end

        # Refuses the `then_set` spelling outside shadow-parsing; while shadow-parsing frozen
        # era text, reads it via `legacy_then_set` instead.
        #
        # @param target [Symbol, String] the field this mutation writes
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] outside shadow-parsing, always; under
        #   shadow-parsing, if `legacy_then_set` names no operation or more than one
        def then_set_impl(target, positional_to = UNSET, **)
          return legacy_then_set(target, positional_to, **) if MetaValidator.shadow_parsing?

          raise Malformed, "#{@name}'s then_set is gone — sets is the word now"
        end

        # Declares a synchronous, atomic delegation of this command's dispatch to one nested
        # entity command; unlike `trigger`/`saga`, the target's given/ensures are enforced as
        # real exceptions, so its refusal is the delegating command's own refusal too.
        #
        # @param target [String, Symbol] the delegated command, dotted `"Entity.Command"`
        # @param with [Hash{Symbol => Symbol, Object}] projects this command's own arguments
        #   onto the target's; a Symbol value names one of this command's own arguments,
        #   anything else is a literal
        # @return [Array<Bluebook::Mutation>] every mutation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `target` is not `"Entity.Command"` shaped
        def delegates_to_impl(target, with: {})
          entity_name, _dot, command_name = target.to_s.rpartition(".")
          if entity_name.empty? || command_name.empty?
            raise Malformed,
                  "#{@name}'s delegates_to #{target.inspect} does not name an entity and a command " \
                  "(\"Entity.Command\") — the same one-hop shape a bare given reference already uses"
          end

          @mutations << Mutation.new(target: target.to_s, op: :delegate, source: with)
        end

        # Declares that this command amends a past event, rather than rewriting it. `reverses:
        # true` auto-derives the corrective `sets` from the original event's own mutations,
        # and is mutually exclusive with an explicit `sets` on the same command.
        #
        # @param event [String, Symbol, Module] the event this command corrects
        # @param as [Symbol, nil] binds the located instance for a `given`/`ensures` to reference
        # @param reason [String, nil] why the correction is made, carried as audit data; required
        # @param reverses [Boolean] auto-derive the corrective `sets` from the original mutations
        # @return [Array<Bluebook::Mutation>] every mutation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `reason` is nil or blank
        def corrects_impl(event, as: nil, reason: nil, reverses: false)
          if reason.to_s.strip.empty?
            raise Malformed,
                  "#{@name}'s corrects #{event.inspect} names no reason — a correction " \
                  "is carried as data (an audit trail needs to say WHY), the same way a " \
                  "given's own description must say something"
          end

          @mutations << Mutation.new(target: event.to_s, op: :corrects,
                                     source: { as: as&.to_s, reason: reason.to_s, reverses: reverses })
        end

        private

        # Folds a positional source into `to:`, and reads arithmetic written there
        # (`to: paid * rate / 100`) as the source it spells.
        def source_of_to(ops, positional_to)
          ops = ops.merge(to: positional_to) unless ops.key?(:to) || positional_to.equal?(UNSET)
          ops[:to].is_a?(Operands::Computation) ? ops.merge(to: ops[:to].to_source) : ops
        end

        # A command's effects are one update set over the pre-dispatch state — a field
        # written twice would make declaration order silently significant.
        def refuse_duplicate_targets!
          return if MetaValidator.shadow_parsing? # frozen era text is history

          seen = {}
          @mutations.select { |mutation| FIELD_EFFECTS.include?(mutation.op) }.each do |mutation|
            earlier = seen[mutation.target.to_sym]
            refuse_double_write!(mutation, earlier) if earlier
            seen[mutation.target.to_sym] = mutation
          end
        end

        def refuse_double_write!(mutation, earlier)
          raise Malformed,
                "#{@name} writes #{mutation.target} twice (#{earlier.op} and #{mutation.op}) — a command's " \
                "effects are one update set over the pre-dispatch state, so each field is written at most once"
        end

        # Refuses a keyword the word does not take, the way a keyword parameter list would.
        def refuse_unknown_ops!(ops, allowed)
          unknown = ops.keys - allowed
          return if unknown.empty?

          raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}"
        end

        def refuse_repeated_target!(target, to)
          return unless to.is_a?(Symbol) && to == target.to_sym

          raise Malformed,
                "#{@name}'s sets :#{target}, to: :#{target} repeats the target — " \
                "sets :#{target} alone already means the same"
        end

        # Records the one mutation `named` selects, refusing a second op.
        def record_mutation(word, target, named)
          if named.size > 1
            raise Malformed,
                  "#{@name}'s #{word} :#{target} tries to #{named.keys.join(" and ")} " \
                  "at once — one mutation, one meaning"
          end

          op, source = named.first
          @mutations << Mutation.new(target: target.to_sym, op: op, source: normalize_append_source(op, source))
        end

        # The ops `then_set` selects between, in the order its refusals name them.
        LEGACY_OPS = %i[append increment decrement multiply clamp remove].freeze
        private_constant :LEGACY_OPS

        # Preserves `then_set`'s exact prior reading (`from:` a synonym for `to:`, no
        # omittable-`to:` shorthand) so frozen era text always re-parses to the same meaning.
        def legacy_then_set(target, positional_to = UNSET, **ops)
          refuse_unknown_ops!(ops, [:to, :from, *LEGACY_OPS])
          ops = ops.merge(to: positional_to) unless ops.key?(:to) || positional_to.equal?(UNSET)

          named = legacy_named_ops(ops)
          refuse_unnamed_then_set!(target) if named.empty?

          record_mutation("then_set", target, named)
        end

        # The ops a `then_set` names, `set` first, the rest in `LEGACY_OPS` order.
        def legacy_named_ops(ops)
          named = {}
          named[:set] = (ops.key?(:to) ? ops[:to] : ops[:from]) if ops.key?(:to) || ops.key?(:from)
          LEGACY_OPS.each { |op| named[op] = ops[op] if ops.key?(op) }
          named
        end

        def refuse_unnamed_then_set!(target)
          raise Malformed,
                "#{@name}'s then_set :#{target} names no operation — " \
                "give it to:, append:, increment:, decrement:, multiply:, clamp:, or remove:"
        end

        # `append:` normally binds a Hash of fields; a bare value (`append: :single_field`)
        # is the one-field shorthand for `append: { value: :single_field }` — without this,
        # downstream code that reads `mutation.source` as a Hash unconditionally would crash.
        def normalize_append_source(oper, source)
          return source unless oper == :append
          return source if source.is_a?(::Hash)

          { value: source }
        end
      end
    end
  end
end
