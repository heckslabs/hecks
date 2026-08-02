require_relative "invariant_violation"

module Hecksagain
  module Runtime
    class Value
      # Closed sets — `one_of` members and `admits:` declarations — and the
      # refusals that make them rules rather than decoration. Extended into
      # Value beside Coercion; `self` is the Value class.
      module Admission
        def admit_member(value_object, fields)
          return if value_object.members.empty?

          discriminant = value_object.attributes.first.name
          offered      = fields[discriminant]
          admitted     = value_object.members.map { |member| member[discriminant].to_s }
          return if admitted.include?(offered.to_s)

          raise InvariantViolation,
                "#{value_object.hecks_name} admits #{admitted.map(&:inspect).join(', ')} — got #{offered.inspect}"
        end

        # THE SAME REFUSAL, FOR A SET NAMED SOMEWHERE ELSE.
        #
        # `admit_member` above refuses a non-member when the value object BEING
        # BUILT is itself the closed set — which is the only shape `one_of` can
        # make, because it SYNTHESISES the set from the values written inline. An
        # `admits:` attribute is the other direction: the value is an ordinary
        # String or a plain text holder, and the set it must belong to was
        # declared once, elsewhere, and is named rather than restated.
        #
        # Without this the word was a DECLARATION and nothing more — read by
        # bin/ir_structs to type a Rust field, read by nobody at the door. A rule
        # that cannot be the one to refuse is decoration, and this language has
        # paid for that mistake before.
        def admit_declared_set(owner, attribute, value)
          return value if attribute.nil? || attribute.admits.nil? || value.nil?

          admitted = admitted_members(owner, attribute)
          offered  = admitted_scalar(value)
          return value if admitted.include?(offered.to_s)

          raise InvariantViolation,
                "#{attribute.name} admits #{attribute.admits} — " \
                "#{admitted.map(&:inspect).join(', ')} — got #{offered.inspect}"
        end

        # `Vocabulary::MutationOp` — the aggregate that HOLDS the set, then the
        # set. Qualified because a closed set is a value object INSIDE an
        # aggregate, which is exactly why `admits` could not be spelled as a
        # reference: `reference_to` reaches aggregate heads and nothing below one.
        #
        # RESOLVED LATE, like `Reference#resolve` and for the same reason — the
        # set may be declared further down the file than the attribute that names
        # it. And REFUSED when it resolves to nothing, also like `Reference`: a
        # link checked against nothing is worse than no link, because it reads
        # like a rule.
        def admitted_members(owner, attribute)
          aggregate_name, set_name = attribute.admits.to_s.split("::", 2)
          chapter = chapter_of(owner)
          set     = set_name && chapter&.aggregate(aggregate_name)&.value_object(set_name)

          unless set
            raise InvariantViolation,
                  "#{attribute.name} admits #{attribute.admits}, which this chapter does not " \
                  "declare — a closed set is named Aggregate::SetName, and it must be one " \
                  "the bluebook actually holds"
          end

          discriminant = set.attributes.first.name
          set.members.map { |member| member.to_h[discriminant].to_s }
        end

        # UP TO THE CHAPTER, from wherever the attribute was declared. A value
        # object's owner is its aggregate and an aggregate's owner is its chapter,
        # so the walk stops at the first construct that can answer for an
        # aggregate BY NAME — which is the chapter, and only the chapter.
        def chapter_of(construct)
          node = construct
          node = node.hecks_owner while node && !node.respond_to?(:aggregate) && node.respond_to?(:hecks_owner)
          node.respond_to?(:aggregate) ? node : nil
        end

        # An admitted value is a SCALAR however it arrived — as a bare string on a
        # plain field, or wrapped in the one-field holder its type names.
        def admitted_scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          fields.size == 1 ? fields.values.first : value
        end

        # A FIELD OF A VALUE OBJECT MAY NAME A SET TOO.
        #
        # Beside check_patterns and for the same reason: `Query::Filter.op` is a
        # plain String field that admits `Vocabulary::QueryComparator`, and the
        # value object is what gets built — no attribute passes through
        # `for_attribute` on the way. Both doors, or the word means one thing on
        # an argument and nothing on a field.
        private def check_admitted(value_object, fields)
          value_object.attributes.each do |attribute|
            next unless attribute.admits

            admit_declared_set(value_object, attribute, fields[attribute.name])
          end
        end
      end
    end
  end
end
