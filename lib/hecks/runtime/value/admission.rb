require_relative "invariant_violation"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class Value
      # Closed sets — `one_of` members and `admits:` declarations — and the
      # refusals that make them rules rather than decoration. Extended into
      # Value beside Coercion; `self` is the Value class.
      module Admission
        # Refuses fields that match no declared member of a closed-set (`one_of`) value object.
        #
        # @param value_object [Bluebook::ValueObject] the type being built; one with no
        #   members is not a closed set and is never refused
        # @param fields [Hash{Symbol => Object}] the offered fields, keyed by attribute name
        # @return [nil] when the type has no members, or some member matches on every
        #   field it names
        # @raise [Runtime::InvariantViolation] if no member matches; the message lists the
        #   admitted values of the first attribute and the one offered
        def admit_member(value_object, fields)
          return if value_object.members.empty?

          discriminant = value_object.attributes.first.name
          offered      = fields[discriminant]
          admitted     = value_object.members.map { |member| member[discriminant].to_s }
          return if value_object.members.any? { |member| member_matches?(member, fields) }

          raise InvariantViolation,
                RefusalWording.render("InvariantViolation", "closed_set_member",
                                      type: value_object.hecks_name,
                                      admitted: admitted.map(&:inspect).join(", "), offered: offered.inspect)
        end

        # Every declared field, not only the discriminant — a multi-column
        # `member` row (`StatementFrequency`'s `cadence`/`retention_months`/
        # `paper_fee_cents`, statements.bluebook) names a whole tuple, and a
        # caller offering the right `cadence` with the wrong
        # `retention_months` is not a genuine member just because the first
        # column happened to match. Comparing only the discriminant
        # (`admitted.include?(offered.to_s)`) stops at that first column —
        # confirmed live: `Value.build(StatementFrequency, cadence:
        # "monthly", retention_months: 999, paper_fee_cents: 999)` would be
        # admitted outright, though no member of the closed set declares that row.
        # A single-field set (`AccountKind`, `LedgerDirection`, ...) has
        # exactly one key here, so this reduces to a discriminant-only
        # comparison for every set that has one column — same refusal,
        # same wording.
        private def member_matches?(member, fields)
          member.all? { |field, value| fields[field].to_s == value.to_s }
        end

        # Checks a value against the closed set its attribute names with `admits:`.
        #
        # The same refusal, for a set named somewhere else.
        #
        # `admit_member` above refuses a non-member when the value object being
        # built is itself the closed set — which is the only shape `one_of` can
        # make, because it synthesises the set from the values written inline. An
        # `admits:` attribute is the other direction: the value is an ordinary
        # String or a plain text holder, and the set it must belong to was
        # declared once, elsewhere, and is named rather than restated.
        #
        # Without this the word was a declaration and nothing more — read by
        # projections, read by nobody at the door. A rule
        # that cannot be the one to refuse is decoration, and this language has
        # paid for that mistake before.
        #
        # @param owner [Bluebook::Aggregate, Bluebook::Entity, Bluebook::ValueObject] the
        #   construct that declares `attribute`; the walk to the chapter starts here
        # @param attribute [Bluebook::Attribute, nil] the attribute being filled; nil, or one
        #   with no `admits:`, means nothing is checked
        # @param value [Object, nil] the coerced value: a bare scalar, or a `Runtime::Value`
        #   holding one field; nil is never checked
        # @return [Object, nil] `value`, unchanged
        # @raise [Runtime::InvariantViolation] if the value is not a member of the named set,
        #   or `admits:` names a set no aggregate in the chapter declares
        def admit_declared_set(owner, attribute, value)
          return value if attribute.nil? || attribute.admits.nil? || value.nil?

          admitted = admitted_members(owner, attribute)
          offered  = admitted_scalar(value)
          return value if admitted.include?(offered.to_s)

          raise InvariantViolation,
                RefusalWording.render("InvariantViolation", "admits_declared_set",
                                      name: attribute.name, admits: attribute.admits,
                                      admitted: admitted.map(&:inspect).join(", "), offered: offered.inspect)
        end

        # Lists the values the closed set named by an attribute's `admits:` allows.
        #
        # `Vocabulary::MutationOp` — the aggregate that holds the set, then the
        # set. Qualified because a closed set is a value object inside an
        # aggregate, which is exactly why `admits` could not be spelled as a
        # reference: `reference_to` reaches aggregate heads and nothing below one.
        #
        # Resolved late, like `Reference#resolve` and for the same reason — the
        # set may be declared further down the file than the attribute that names
        # it. And refused when it resolves to nothing, also like `Reference`: a
        # link checked against nothing is worse than no link, because it reads
        # like a rule.
        #
        # @param owner [Bluebook::Aggregate, Bluebook::Entity, Bluebook::ValueObject] the
        #   construct that declares `attribute`
        # @param attribute [Bluebook::Attribute] an attribute whose `admits` is
        #   `"Aggregate::SetName"`
        # @return [Array<String>] each member's value for the set's first attribute, as a String,
        #   in declaration order
        # @raise [Runtime::InvariantViolation] if `admits` is not qualified, no chapter is
        #   reachable from `owner`, or the chapter declares no such aggregate or value object
        def admitted_members(owner, attribute)
          aggregate_name, set_name = attribute.admits.to_s.split("::", 2)
          chapter = chapter_of(owner)
          set     = set_name && chapter&.aggregate(aggregate_name)&.value_object(set_name)

          unless set
            raise InvariantViolation,
                  RefusalWording.render("InvariantViolation", "undeclared_set",
                                        name: attribute.name, admits: attribute.admits)
          end

          discriminant = set.attributes.first.name
          set.members.map { |member| member.to_h[discriminant].to_s }
        end

        # Walks `hecks_owner` links upward until it reaches the chapter.
        #
        # Up to the chapter, from wherever the attribute was declared. A value
        # object's owner is its aggregate and an aggregate's owner is its chapter,
        # so the walk stops at the first construct that can answer for an
        # aggregate by name — which is the chapter, and only the chapter.
        #
        # @param construct [Bluebook::ValueObject, Bluebook::Entity, Bluebook::Aggregate,
        #   Bluebook::Chapter, nil] the construct to start from; the chapter answers itself
        # @return [Bluebook::Chapter, nil] the first construct on the way up that responds to
        #   `aggregate`; nil when the chain ends without one
        def chapter_of(construct)
          node = construct
          node = node.hecks_owner while node && !node.respond_to?(:aggregate) && node.respond_to?(:hecks_owner)
          node.respond_to?(:aggregate) ? node : nil
        end

        # Unwraps a one-field value object to the scalar it holds, so membership compares scalars.
        #
        # An admitted value is a scalar however it arrived — as a bare string on a
        # plain field, or wrapped in the one-field holder its type names.
        #
        # @param value [Object] a bare scalar, or a `Runtime::Value`
        # @return [Object] the sole field's value for a one-field `Runtime::Value`; otherwise
        #   `value` itself, a multi-field `Runtime::Value` included
        def admitted_scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          fields.size == 1 ? fields.values.first : value
        end

        # A field of a value object may name a set too.
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
