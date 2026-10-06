module Hecks
  module Bluebook
    module DSL
      class ReadModelBuilder
        # The build-time refusals of a read model: every option and reduction must resolve against
        # the many-side heads its includes declared, which are only known once the body has run.
        module Sealing
          private

          def seal_all
            seal_query_options
            seal_group_by
            seal_aggregation
            seal_cursor
          end

          # where/order_by/limit/offset/authorize's tenant apply to the many-side collections;
          # the reference target is a single row. Every `on:` must name a many-side include, and
          # any untargeted option needs exactly one many-side head (ADR 0055).
          def seal_query_options
            many = Array(@aggregate_heads).select { |head| head[:many] }

            validate_declared_targets!(many)
            return unless untargeted_option_declared?
            return if many.size == 1

            raise Malformed,
                  "#{@name} declares where/order_by/limit/offset but includes #{many.size} many-side " \
                  "aggregates, not exactly one — these options apply to a single collection; " \
                  "name which one with `on:` (e.g. `where(field: value, on: Character)`), or drop the options"
          end

          # Refuses an `on:` that does not name one of the many-side includes.
          def validate_declared_targets!(many)
            many_by_aggregate = many.to_h { |head| [head[:aggregate], head] }

            declared_targets.compact.uniq.each do |target|
              next if many_by_aggregate.key?(target)

              raise Malformed,
                    "#{@name}'s `on: #{target}` doesn't name one of its own many-side included " \
                    "aggregates (it includes #{many.map { |head| head[:aggregate] }.join(", ")} as " \
                    "many-side heads)"
            end
          end

          def declared_targets
            Array(@wheres).map(&:target) + [@order_by&.target, @limit&.target, @offset&.target]
          end

          # `authorize`'s `tenant:` has no `on:`, so it always counts as untargeted.
          def untargeted_option_declared?
            Array(@wheres).any? { |where| where.target.nil? } ||
              [@order_by, @limit, @offset].any? { |option| option && option.target.nil? } ||
              @authorization&.tenant
          end

          # Same rule as `seal_query_options`: `group_by` needs exactly one many-side head.
          def seal_group_by
            return unless @group_by&.any?

            many = many_side_count
            return if many == 1

            raise Malformed,
                  "#{@name} declares group_by but includes #{many} many-side " \
                  "aggregates, not exactly one — group_by nests a single collection's " \
                  "own rows; name which one by including only it"
          end

          # Every reduction (`Behaviour::ReadModel::REDUCTION_FIELDS`) needs exactly one
          # many-side head, cannot be declared alongside another, and cannot combine with
          # `group_by`: a read model reports one shape.
          def seal_aggregation
            declared = Behaviour::ReadModel::REDUCTION_FIELDS
                       .select { |ivar, _| instance_variable_get(:"@#{ivar}") }.values
            return if declared.empty?

            refuse_mixed_shapes!(declared)
            many = many_side_count
            return if many == 1

            raise Malformed,
                  "#{@name} declares #{declared.first} but includes #{many} many-side " \
                  "aggregates, not exactly one — #{declared.first} reduces a single " \
                  "collection's own rows; name which one by including only it"
          end

          def refuse_mixed_shapes!(declared)
            if @group_by&.any?
              raise Malformed,
                    "#{@name} declares #{declared.join("/")} together with group_by — a read " \
                    "model reports one shape; choose one"
            end
            return unless declared.size > 1

            joiner = declared.size == 2 ? "both #{declared.join(" and ")}" : declared.join(", ")
            raise Malformed, "#{@name} declares #{joiner} — a read model reports one shape; choose one"
          end

          def many_side_count = Array(@aggregate_heads).count { |head| head[:many] }

          # `cursor` is parsed but no interpreter applies it, so it is refused rather than
          # letting an author believe cursor pagination happens.
          def seal_cursor
            return unless @cursor

            raise Malformed,
                  "#{@name} declares cursor, but no interpreter implements cursor " \
                  "pagination — use limit/offset instead"
          end
        end
      end
    end
  end
end
