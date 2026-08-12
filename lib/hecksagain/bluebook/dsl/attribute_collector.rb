module Hecksagain
  module Bluebook
    module DSL
      module AttributeCollector
        ListOf = Struct.new(:type)
        OneOf  = Struct.new(:values)

        def attributes = @attributes ||= []

        # Value objects synthesised from inline closed sets, collected here and
        # installed by whoever owns value objects (the aggregate).
        def closed_sets = @closed_sets ||= []

        # `admits:` names a closed set that is ALREADY DECLARED elsewhere —
        #
        #   attribute :op, String, admits: "Vocabulary::QueryComparator"
        #
        # which is the difference between it and `one_of`: `one_of` SYNTHESISES
        # a fresh value object named for the attribute, so it can only ever name
        # something new. `admits` points at a set the language already holds, so
        # the same set can be named from many places without being written twice.
        #
        # QUALIFIED, because a closed set is a value object INSIDE an aggregate
        # and `reference_to` reaches heads only — so this is text, checked where
        # it is read rather than by reference resolution.
        #
        # AND WRITTEN AS TEXT, not as the constant path `Vocabulary::QueryComparator`
        # it reads like. The constant spelling was tried — `ConstShim` returning
        # a Module so Ruby's `::` reaches a second `const_missing` — and it
        # cannot hold: `Facade::Surface` installs every aggregate name as a
        # TOP-LEVEL constant, so the moment any facade exists, `Vocabulary`
        # resolves to that module and the shim is never asked. A spelling that
        # works only until a facade is built is worse than a quoted one.
        def attribute(name, type = String, default: nil, optional: false, pattern: nil,
                      admits: nil)
          # moved to the language: FieldName invariant, on Root.Attribute

          refuse_unshared_pattern(name, pattern) if pattern

          type = synthesise_closed_set(name, type) if type.is_a?(OneOf)
          list = type.is_a?(ListOf)
          attributes << Attribute.new(
            name:     name,
            type:     list ? type.type : type,
            list:     list,
            default:  default,
            optional: optional,
            pattern:  pattern,
            admits:   admits
          )
        end

        def list_of(type) = ListOf.new(type)

        # A closed set declared INLINE on the attribute:
        #
        #   attribute :status, one_of("open", "shut")
        #
        # Desugars to a value object named for the attribute, so it goes through
        # exactly the machinery a hand-written one_of does — and so the
        # attribute's type is still a DECLARED value object, which is now a
        # structural rule rather than a predicate.
        #
        # An earlier reading of this spelling parsed it and threw the values
        # away: the attribute became a plain String and the closed set meant
        # nothing, in a construct that looked supported. The desugaring is
        # pinned now — the same bluebook must always yield the same IR.
        def one_of(*values) = OneOf.new(values)

        private

        # A pattern is refused AT DECLARATION, not when a value first meets it :
        # a regex whose meaning depends on which engine reads it is a defect in
        # the bluebook, and a bluebook that loads is one whose patterns carry
        # one meaning. PatternSubset says which those are, and why each is refused.
        def refuse_unshared_pattern(name, pattern)
          rejection = PatternSubset.validate(pattern)
          return unless rejection

          raise Malformed,
                "#{name}'s pattern #{pattern.inspect} uses a #{rejection.construct} — " \
                "#{rejection.reason}"
        end

        def synthesise_closed_set(name, one_of)
          type = Naming.pascal(name)
          closed_sets << ValueObject.declare(
            name:       type,
            attributes: [Attribute.new(name: :value, type: "String")],
            members:    one_of.values.map { |value| { value: value.to_s } },
            closed_set: true
          )
          type
        end

        # `identified_by :reference` — the bare-field form, DERIVING the path
        # instead of spelling it: `field`'s own already-declared attribute
        # names a value object, and when that value object holds EXACTLY one
        # field there is only one thing `identified_by { field.value }` could
        # ever have meant. More than one field is genuinely ambiguous (which
        # one names the record?) — refused, naming every candidate, rather
        # than guessing `.value`-if-present the way an earlier draft of this
        # did (silently wrong the moment a second field, `pad`, arrives on
        # what used to be single-field). Shared by AggregateBuilder and
        # EntityBuilder (both include this module) — each resolves it at its
        # own BUILD time, not at `identified_by`'s own call time, since every
        # real bluebook declares identified_by BEFORE the attribute it
        # names, so the attribute (and its own value-object type) don't
        # exist to look up yet at that point.
        def resolve_identity_field!(field, value_objects, context_name)
          attr = attributes.find { |a| a.name == field }
          raise Malformed, "#{context_name}.identified_by :#{field} names no attribute #{context_name} declares" unless attr

          if attr.reference?
            raise Malformed,
                  "#{context_name}.identified_by :#{field} names a reference — " \
                  "write identified_by { #{field}.value }, naming the field explicitly"
          end

          vo = value_objects.find { |v| v.hecks_name.to_s == attr.type.to_s }
          return [field.to_s] unless vo # a bare primitive type — already itself scalar

          case vo.attributes.size
          when 1
            ["#{field}.#{vo.attributes.first.name}"]
          else
            raise Malformed,
                  "#{context_name}.identified_by :#{field} names #{attr.type}, which has " \
                  "#{vo.attributes.size} fields (#{vo.attributes.map(&:name).join(', ')}) — " \
                  "a bare field name only derives a path when its own value object has " \
                  "exactly one field; write identified_by { #{field}.<field> } naming the " \
                  "specific one"
          end
        end

        # `identified_by PizzaName` — the bare-TYPE form, mirroring
        # `reference_to`'s own shape exactly: pass the value object, not a
        # field name, and the attribute itself is MINTED here (no separate
        # `attribute :name, PizzaName` line needed at all) the same way
        # `reference_to Team` mints `:team_id` on its own. The minted
        # attribute's own name is `as:` if given, or `Naming.snake` of the
        # type otherwise — same convention `reference_to`'s own `as:`
        # already uses. Requires EXACTLY one field on the value object, for
        # the identical reason `resolve_identity_field!` does — refused,
        # naming every candidate, rather than guessing.
        def resolve_identity_type!(type, as, insert_at, value_objects, context_name)
          target = Naming.demodulise(type)
          vo = value_objects.find { |v| v.hecks_name.to_s == target }
          raise Malformed, "#{context_name}.identified_by names #{target}, which is not a declared value object" unless vo

          if vo.attributes.size != 1
            raise Malformed,
                  "#{context_name}.identified_by names #{target}, which has #{vo.attributes.size} " \
                  "fields (#{vo.attributes.map(&:name).join(', ')}) — identified_by ValueObject only " \
                  "derives a path when it has exactly one field; write identified_by { field.<field> } " \
                  "naming the specific one"
          end

          field = (as || Naming.snake(target)).to_sym
          attribute(field, target)
          # MOVED to `insert_at` — the attribute count AT THE MOMENT
          # `identified_by` was actually called, captured by the caller —
          # not left where `attribute` just appended it. Resolution happens
          # at BUILD time, after every other attribute in the block has
          # already run, so appending would put the identity field LAST
          # regardless of where `identified_by` was actually written.
          # Most real bluebooks write it first (insert_at 0); one (a
          # ScheduledPayment corpus member) writes it after a reference_to
          # and an attribute — this matches either, and whatever a person
          # hand-writing `attribute field, Type` at that exact point,
          # the way this used to be required, would have produced.
          attributes.insert(insert_at, attributes.pop)
          ["#{field}.#{vo.attributes.first.name}"]
        end
      end
    end
  end
end
