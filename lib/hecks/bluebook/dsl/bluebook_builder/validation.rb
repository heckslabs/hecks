require_relative "validation/provisions"
require_relative "validation/references"
require_relative "validation/event_shapes"
require_relative "validation/with_projections"
require_relative "validation/query_hops"
require_relative "validation/projected_fields"
require_relative "validation/correlation_keys"

module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        # Whole-chapter, cross-aggregate checks that `#build` runs once a chapter is assembled.
        # Extended onto BluebookBuilder: pure functions of their arguments, no builder state.
        # Each family of checks lives in its own module under `validation/`.
        module Validation
          include Provisions
          include References
          include EventShapes
          include WithProjections
          include QueryHops
          include ProjectedFields
          include CorrelationKeys

          # Runs every whole-chapter check against one assembled chapter.
          # Public so `MetaValidator.judge_deferred!` can call it with no builder instance.
          #
          # @param bluebook [Bluebook::Chapter] the assembled chapter to validate
          # @return [void]
          # @raise [Bluebook::DSL::Malformed] if any check finds a violation
          # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if a
          #   `correlates_by` resolves to something other than a scalar field
          def validate_assembled!(bluebook)
            validate_not_the_gem_module!(bluebook)
            validate_declarations!(bluebook)
            validate_owner_stamped!(bluebook)
            validate_provisions!(bluebook)
          end

          private

          def validate_declarations!(bluebook)
            # an attribute type references its Shape, so an undeclared value object
            # fails resolution
            validate_reference_value_objects!(bluebook.aggregates)
            validate_correlation_keys!(bluebook.process_managers, bluebook.aggregates)
            validate_no_bidirectional_references!(bluebook.aggregates)
            return if MetaValidator.shadow_parsing?

            validate_event_shapes!(bluebook.aggregates)
            validate_with_projections!(bluebook.policies, bluebook.process_managers, bluebook.aggregates)
          end

          # Hops resolve only now: `Bluebook.new` has just stamped `hecks_owner` on
          # every aggregate. A `projects` reference needs the same owner-stamped aggregates
          # to resolve (ADR 0025).
          def validate_owner_stamped!(bluebook)
            infer_hop_query_arguments!(bluebook)
            validate_query_hops!(bluebook)
            validate_projected_fields!(bluebook)
          end
        end
      end
    end
  end
end
