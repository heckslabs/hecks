# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # An aggregate that holds one record, by its own rule: its identity is a value object whose
        # invariant says the value is one literal (`value == "site"`), as a settings row is keyed.
        module Single
          # `value == "<literal>"`, the whole of the rule.
          RULE = /\Avalue == "([^"]+)"\z/

          module_function

          # @param agg [Bluebook::Aggregate] a declared aggregate
          # @return [String, nil] the literal its identity must be, or nil
          def literal(agg)
            object = identity_object(agg)
            object&.invariants&.filter_map { |rule| RULE.match(rule.canonical.to_s)&.[](1) }&.first
          end

          # @return [Bluebook::ValueObject, nil] the value object the identity attribute is
          def identity_object(agg)
            type = agg.attributes.find { |attr| attr.name.to_s == agg.identified_by.to_s }&.type.to_s
            agg.value_objects.find { |candidate| candidate.hecks_name == type }
          end
        end
      end
    end
  end
end
