require_relative "invariant_violation"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class Value
      # Closed sets (`one_of` members and `admits:` declarations) and their refusals.
      # Extended into Value beside Coercion.
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
          return if value_object.members.any? { |member| member_matches?(member, fields) }

          refuse_non_member!(value_object, fields)
        end

        # Checks a value against the closed set its attribute names with `admits:`.
        #
        # Unlike `admit_member`, the set is declared elsewhere and named, not written inline.
        #
        # @param owner [Bluebook::Aggregate, Bluebook::Entity, Bluebook::ValueObject] declares
        #   `attribute`; the walk to the chapter starts here
        # @param attribute [Bluebook::Attribute, nil] nil, or one with no `admits:`, checks nothing
        # @param value [Object, nil] a bare scalar or a one-field `Runtime::Value`; nil is skipped
        # @return [Object, nil] `value`, unchanged
        # @raise [Runtime::InvariantViolation] if the value is not a member of the named set,
        #   or `admits:` names a set no aggregate in the chapter declares
        def admit_declared_set(owner, attribute, value)
          return value if attribute.nil? || attribute.admits.nil? || value.nil?

          admitted = admitted_members(owner, attribute)
          offered  = admitted_scalar(value)
          return value if admitted.include?(offered.to_s)

          raise InvariantViolation,
                RefusalWording.render_site("InvariantViolation", "admits_declared_set",
                                           name: attribute.name, admits: attribute.admits,
                                           admitted: admitted, offered: offered.inspect)
        end

        # Lists the values the closed set named by an attribute's `admits:` allows.
        #
        # Resolved late, since the set may be declared below the attribute, and refused when
        # it resolves to nothing.
        #
        # @param owner [Bluebook::Aggregate, Bluebook::Entity, Bluebook::ValueObject] declares
        #   `attribute`
        # @param attribute [Bluebook::Attribute] an attribute whose `admits` is `"Aggregate::Set"`
        # @return [Array<String>] each member's first-attribute value as a String, in order
        # @raise [Runtime::InvariantViolation] if `admits` is not qualified, no chapter is
        #   reachable from `owner`, or the chapter declares no such aggregate or value object
        def admitted_members(owner, attribute)
          set = declared_set(owner, attribute)
          unless set
            raise InvariantViolation,
                  RefusalWording.render_site("InvariantViolation", "undeclared_set",
                                             name: attribute.name, admits: attribute.admits)
          end

          discriminant = set.attributes.first.name
          set.members.map { |member| member.to_h[discriminant].to_s }
        end

        # Walks `hecks_owner` links upward until it reaches the chapter.
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
        # @param value [Object] a bare scalar, or a `Runtime::Value`
        # @return [Object] the sole field's value for a one-field `Runtime::Value`; otherwise
        #   `value` itself, a multi-field `Runtime::Value` included
        def admitted_scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          fields.size == 1 ? fields.values.first : value
        end

        private

        def refuse_non_member!(value_object, fields)
          discriminant = value_object.attributes.first.name
          admitted     = value_object.members.map { |member| member[discriminant].to_s }
          raise InvariantViolation,
                RefusalWording.render_site("InvariantViolation", "closed_set_member",
                                           type: value_object.hecks_name,
                                           admitted: admitted, offered: fields[discriminant].inspect)
        end

        # Compares every declared field, not only the first: a multi-column `member` row is a
        # whole tuple, so a matching first column with a wrong second is not a member.
        def member_matches?(member, fields)
          member.all? { |field, value| fields[field].to_s == value.to_s }
        end

        # The value object `attribute.admits` names (`"Aggregate::Set"`), when the chapter declares
        # it.
        def declared_set(owner, attribute)
          aggregate_name, set_name = attribute.admits.to_s.split("::", 2)
          chapter = chapter_of(owner)
          set_name && chapter&.aggregate(aggregate_name)&.value_object(set_name)
        end

        # Applies `admits:` to value-object fields too, which never pass through `for_attribute`.
        def check_admitted(value_object, fields)
          value_object.attributes.each do |attribute|
            next unless attribute.admits

            admit_declared_set(value_object, attribute, fields[attribute.name])
          end
        end
      end
    end
  end
end
