require_relative "null_policy"
require_relative "../../runtime/value"

module Hecks
  module QuerySpecification
    module Common
      # The one comparator table shared by `Ports::Query::InMemory` and
      # `Runtime::QueryInterpreter`, so every engine reads a where-clause identically.
      module Comparison
        module_function

        # Unwraps a value object to the one scalar a comparison can mean.
        #
        # Only a sole numeric member, or a sole member of any type, is unambiguous; anything
        # else is returned unchanged rather than guessed at. Ambiguous declarations are refused
        # at load, so this is a backstop.
        #
        # @param value [Runtime::Value, Hash, Object, nil] a held or wanted value; a
        #   `Runtime::Value` is read through its `to_h`
        # @return [Object, nil] the sole numeric member, or the sole member, of a Hash-shaped
        #   value; otherwise `value` unchanged (a `Runtime::Value` comes back as its Hash)
        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          return value unless value.is_a?(Hash)

          numerics = value.values.grep(Numeric)
          return numerics.first if numerics.size == 1
          return value.values.first if value.size == 1

          value
        end

        # Lists the members a value object offers a scalar comparison, for a refusal
        # that can name them. Empty when the value object is unambiguous.
        #
        # @param value_object [Class<Bluebook::ValueObject>] the declared shape (a subclass
        #   minted by `Bluebook::ValueObject.declare`, closed sets included) a query field names
        # @return [Array<Symbol>] every attribute name when no single member can be meant;
        #   `[]` when there is exactly one attribute, or exactly one typed `Integer`,
        #   `Float` or `Numeric`
        def ambiguous_members(value_object)
          numerics = value_object.attributes.select { |a| NUMERIC_TYPES.include?(a.type.to_s) }
          return [] if numerics.size == 1 || value_object.attributes.size == 1

          value_object.attributes.map(&:name)
        end

        NUMERIC_TYPES = %w[Integer Float Numeric].freeze

        # Decides whether one where-clause comparison holds between the value a record
        # holds and the value the query wants.
        #
        # @param operation [Symbol, String] `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `in`,
        #   `contains` or `none_in_state`
        # @param held [Object, nil] the record's own value for the field
        # @param want [Object, nil] the value compared against
        # @param registry [Runtime::Registry, nil] used only by `none_in_state`
        # @return [Boolean] whether the comparison holds
        # @raise [Runtime::WiringError] if `operation` names no comparator in this table
        def holds?(operation, held, want, registry: nil)
          # A NULL satisfies no comparison (`none_in_state` is exempt); see NullPolicy.
          return false if NullPolicy.unmatchable?(operation, held, want)

          name = operation.to_s
          return lower_bound_holds?(name, held, want) if %w[lt lte].include?(name)
          return upper_bound_holds?(name, held, want) if %w[gt gte].include?(name)

          other_holds?(name, held, want, registry)
        end

        # The `lt` and `lte` cases of `holds?`.
        def lower_bound_holds?(name, held, want)
          case name
          when "lt"       then ordered?(held, want) && held < want
          when "lte"      then ordered?(held, want) && held <= want
          end
        end

        # The `gt` and `gte` cases of `holds?`.
        def upper_bound_holds?(name, held, want)
          case name
          when "gt"       then ordered?(held, want) && held > want
          when "gte"      then ordered?(held, want) && held >= want
          end
        end

        # The remaining cases of `holds?`.
        def other_holds?(name, held, want, registry)
          case name
          when "eq"       then held == want
          when "ne"       then held != want
          when "in"       then any_member_in?(held, want)
          when "contains" then contains?(held, want)
          when "none_in_state" then none_in_state?(held, want, registry)
          else
            # Backstop: an unrecognized comparator must refuse, never read as `eq`.
            raise Runtime::WiringError, "no comparator handles #{name.inspect} — add one before declaring it"
          end
        end

        # Checks that both operands of an ordered comparison are numbers.
        #
        # Ordered comparators are numeric-only and silently false otherwise; a where-clause
        # never raises.
        #
        # @param held [Object, nil] the record's own value for the field
        # @param want [Object, nil] the value compared against
        # @return [Boolean] `true` only when both are `Numeric`
        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # Reads a comparator's list operand as the Strings membership is tested against.
        #
        # `in` accepts an Array or a comma-separated String; `contains` reads the stored
        # field instead (see `contains?`).
        #
        # @param value [Array, String, Object, nil] an Array of elements, or anything whose
        #   `to_s` is a comma-separated list such as `"a, b,c"`
        # @return [Array<String>] one String per member: Array elements unwrapped through
        #   `comparable` then `to_s`; split parts stripped of surrounding whitespace; `[]`
        #   for `nil` or an empty String
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
        end

        # Answers `in`: whether the held value, or any element of a held Array,
        # occurs in the wanted list.
        #
        # @param held [Array, Object] the record's own value; an Array contributes each
        #   element as a candidate, anything else is the single candidate
        # @param want [Array, String, Object] the wanted set, read through `members`
        # @return [Boolean] whether any candidate, unwrapped through `comparable` and
        #   compared as a String, is a wanted member
        def any_member_in?(held, want)
          wanted = members(want)
          candidates = held.is_a?(Array) ? held : [held]

          candidates.any? { |candidate| wanted.include?(comparable(candidate).to_s) }
        end

        # Answers `contains`: element membership for a held Array, substring for anything else.
        #
        # A scalar is not comma-split, so free text containing a comma matches the way
        # SQL's `instr`/`position` does.
        #
        # @param held [Array, Object] the record's own value; anything but an Array is
        #   read through `to_s`
        # @param want [Object] the element or substring looked for, compared as its `to_s`
        # @return [Boolean] whether `held` has `want` as a member (Array) or a substring
        def contains?(held, want)
          return members(held).include?(want.to_s) if held.is_a?(Array)

          held.to_s.include?(want.to_s)
        end

        # Answers `none_in_state` by looking the held identity up in another aggregate's
        # repository and reading that record's state.
        #
        # Holds when no such record is in the named state. No registry, aggregate or record
        # reads as "not excluded". The target is found by bare name; the first match wins.
        #
        # @param held [Object, nil] this record's own field value, the target record's identity
        # @param want [String, Symbol] `"Aggregate:state"`, split on the first colon
        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [Boolean] `false` only when the target record is in the named state
        # @raise [Runtime::WiringError] if the target's repository cannot be wired
        def none_in_state?(held, want, registry)
          return true unless registry

          aggregate_name, state = want.to_s.split(":", 2)
          target = find_aggregate_by_name(registry, aggregate_name)
          return true unless target

          target_domain, target_ir = target
          record = registry.repository(target_domain, target_ir).find(held)
          return true unless record

          # The state lives on the target's lifecycle field, else on `:state`.
          field = target_ir.lifecycle&.field || :state
          comparable(record.state[field]) != state
        end

        # Searches every loaded domain for an aggregate by its bare name, taking
        # the first match in the registry's load order.
        #
        # @param registry [Runtime::Registry] the booted registry whose bluebooks are searched
        # @param name [String, nil] the aggregate's bare `hecks_name`, such as `"Claim"`
        # @return [Array(String, Bluebook::Aggregate), nil] the owning domain's name and the
        #   aggregate; `nil` when no loaded domain declares one by that name
        def find_aggregate_by_name(registry, name)
          registry.bluebooks.each do |domain, bluebook|
            aggregate = bluebook.aggregates.find { |a| a.hecks_name == name }
            return [domain, aggregate] if aggregate
          end
          nil
        end
      end
    end
  end
end
