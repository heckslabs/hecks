module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # The names a `for_each` policy's `with:` may read off a fan-out row, mirroring what
          # `PolicyInterpreter::Arguments#trigger_args` offers a projection at runtime.
          module FanOutRows
            private

            # The names a row of the policy's `for_each` query carries: the row's id, the
            # aggregate's attributes, lifecycle field and projected fields, and the key the
            # trigger addresses a row by. Nil when the query's aggregate is not in this chapter,
            # which leaves the source unchecked.
            #
            # @return [Array<Symbol>, nil]
            def fan_out_row_names(policy, aggregates, target)
              return nil if policy.for_each.to_s.empty? || policy.for_each.to_s.include?("::")

              aggregate_name = policy.for_each.to_s.split(".", 2).first
              aggregate = aggregates.find { |candidate| candidate.hecks_name == aggregate_name }
              return nil unless aggregate

              [:id, *row_field_names(aggregate), *row_key_names(target, aggregate_name)]
            end

            def row_field_names(aggregate)
              names = aggregate.attributes.map(&:name) + aggregate.projected_fields.map(&:name)
              names += aggregate.identity_heads.map(&:to_sym)
              aggregate.lifecycle ? names << aggregate.lifecycle.field.to_sym : names
            end

            def row_key_names(target, aggregate_name)
              key = target&.addressing_key_for(aggregate_name)
              key ? [key.to_sym] : []
            end
          end
        end
      end
    end
  end
end
