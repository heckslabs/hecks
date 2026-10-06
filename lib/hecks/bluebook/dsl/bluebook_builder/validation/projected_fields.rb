module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks that each `projects` reference resolves to an aggregate declaring the remote
          # field as a scalar, once every aggregate in the chapter exists.
          module ProjectedFields
            private

            # Checks each `projects` reference resolves to an aggregate declaring
            # `remote_field` as a scalar. A single hop never reaches HopPath::MAX_HOPS, so
            # :too_deep is not special-cased.
            def validate_projected_fields!(bluebook)
              bluebook.aggregates.each do |aggregate|
                aggregate.projected_fields.each { |field| validate_projected_field!(aggregate, field) }
              end
            end

            # Checks that one `projects` field's reference resolves to a real scalar.
            def validate_projected_field!(aggregate, field)
              plan = projection_plan(aggregate, field)
              refuse_unresolvable_projection!(aggregate, field, plan) if plan.refusal == :unresolvable
              validate_projection_target!(aggregate, field, plan)
            end

            def validate_projection_target!(aggregate, field, plan)
              target = plan.hops.last.target
              remote_attribute = target.attributes.find { |candidate| candidate.name.to_s == plan.tail }
              return if remote_attribute.nil? && implicit_projection_target?(target, plan.tail)

              refuse_undeclared_projection!(aggregate, field, target, plan) unless remote_attribute
              refuse_non_scalar_projection!(aggregate, field, target, plan) unless projectable_scalar?(target, remote_attribute)
            end

            def projection_plan(aggregate, field)
              QuerySpecification::HopPath.plan("#{field.reference}/#{field.remote_field}", aggregate.attributes)
            end

            # A lifecycle field is a plain string by construction, so a name match is enough (as in
            # `validate_hop_tail!`). A projection may chain through another projection;
            # `projected_fields` is separate from `attributes`, and a projected value is always a
            # scalar by construction, so a name match is enough there too.
            def implicit_projection_target?(target, tail)
              target.lifecycle&.field.to_s == tail || target.projected_fields.any? { |f| f.name.to_s == tail }
            end

            def refuse_unresolvable_projection!(aggregate, field, plan)
              raise Malformed,
                    "#{aggregate.hecks_name}.projects :#{field.name} reads through :#{field.reference}, " \
                    "which hops to #{plan.hops.last.target_name}, which this chapter never declares — " \
                    "a projection through an aggregate this chapter cannot see resolves to nothing"
            end

            def refuse_undeclared_projection!(aggregate, field, target, plan)
              raise Malformed,
                    "#{aggregate.hecks_name}.projects :#{field.name} reads #{target.hecks_name}'s own " \
                    "#{plan.tail.inspect}, which #{target.hecks_name} never declares"
            end

            def refuse_non_scalar_projection!(aggregate, field, target, plan)
              raise Malformed,
                    "#{aggregate.hecks_name}.projects :#{field.name} reads #{target.hecks_name}'s own " \
                    "#{plan.tail.inspect}, which is not a scalar — a projected field copies a single " \
                    "value, never a reference, a value object, or a list"
            end

            def projectable_scalar?(target, attribute)
              !attribute.list? && !attribute.reference? && target.value_object(attribute.type).nil?
            end
          end
        end
      end
    end
  end
end
