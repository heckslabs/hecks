require_relative "../rendering"
require_relative "errors"
require_relative "value"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "../ports/query/in_memory"
require_relative "../query_specification/field_path"

module Hecks
  module Runtime
    # Interprets one declared `read_model`: resolves its `include`d heads and applies
    # any group_by/count/median reduction, preferring a native SQLite path when it can.
    class ReadModelInterpreter
      # @param registry [Runtime::Registry] the booted registry whose repositories
      #   this interpreter reads
      def initialize(registry) = @registry = registry

      # Runs one declared read model and returns its projected rows.
      # @param domain [String, Symbol] the domain the read model is declared in
      # @param model [Bluebook::ReadModel] the read model to run
      # @param args [Hash] the query's declared arguments
      # @return [Array<Hash>] a one-element array of head name => projected rows
      # @raise [Runtime::TypeMismatch] if a reference is a whole object, or median is non-numeric
      # @raise [Runtime::NotFound] if the reference argument names no record
      # @raise [KeyError] if a rooted read model is asked without its reference argument
      # @raise [ArgumentError] if `group_by`/`median` names an undeclared field
      # @raise [Runtime::InvariantViolation] if two rows collide on a full `group_by` key
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def call(domain, model, args)
        project(domain, model, args)
      end

      private

      # Splitting this into smaller methods would scatter the root-first/SQLite/join
      # ordering across boundaries where a future editor could silently break it.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/MethodLength
      # rubocop:disable-next Metrics/PerceivedComplexity
      def project(domain, model, args)
        bluebook = @registry.bluebook(domain)
        rootless = model.reference_target.nil?
        # Refused before the adapter early-return, so both paths refuse identically
        # rather than one silently opening a wrapped reference the other reads whole.
        refuse_object_reference(model, args) unless rootless
        reference_id = reference(args.fetch(model.reference_name)) unless rootless
        # Computed off the original model, before TenantScope wraps it, so this
        # reflects what the bluebook author declared, not the synthetic tenant
        # clause added underneath (ADR 0055; `on:` allows more than one head).
        eligible = model.filtered_head_names
        model = TenantScope.apply(model, args)
        # A rootless, `group_by`, `count`, or `median` model always runs the
        # in-process loop below — none of those are pushed down into
        # `query_read_model`, a known limit, not a silent one.
        unless rootless || model.group_by.any? || model.count? || model.median_field
          repository = @registry.read_repository(domain, bluebook.aggregate(model.reference_target))
          if repository.respond_to?(:query_read_model) && repository.adapter.respond_to?(:query_read_model)
            return repository.query_read_model(domain, model, args,
                                               bluebook)
          end
        end

        # Root heads run first regardless of declared `include` order — a many-side
        # head declared before its root would otherwise match against an empty
        # `projected`. `partition`, not `sort_by`, which is not guaranteed stable.
        root_heads, other_heads = model.aggregate_heads.partition { |head| head[:aggregate] == model.reference_target }
        projected = []
        rows_by_as = {}
        (root_heads + order_other_heads(bluebook, root_heads, other_heads)).each do |head|
          rows = if head[:aggregate] == model.reference_target
                   [fetch(bluebook, domain, head[:aggregate], reference_id)]
                 elsif rootless
                   # A rootless model has no root to FK-match against, so each head
                   # reads independently; there is no DSL for cross-joining rootless
                   # heads together, a deliberate scope limit, not a gap to grow into.
                   records(bluebook, domain, head[:aggregate])
                 else
                   matching(records(bluebook, domain, head[:aggregate])) do |record|
                     projected.any? do |source|
                       reference_fields(bluebook.aggregate(head[:aggregate]), source[:aggregate]).any? do |field|
                         source[:rows].any? { |parent| reference(record[field]) == parent.id }
                       end
                     end
                   end
                 end
          rows = Ports::Query::InMemory.execute(rows, model.options_for(head[:as]), args) if eligible.include?(head[:as])
          projected << { aggregate: head[:aggregate], rows: rows }
          rows_by_as[head[:as]] = head[:many] ? rows : rows.first
        end
        # Declared order is preserved in the output — only the computation above
        # needed reordering.
        heads = model.aggregate_heads.to_h { |head| [head[:as], rows_by_as[head[:as]]] }
        grouped_head = group_by_target(model, bluebook)
        reduced_head = aggregation_target(model, bluebook)
        [heads.each_with_object({}) do |(as, value), out|
          out[as] = if grouped_head && as == grouped_head[:as]
                      nest(value.map { |record| Value.materialize_unwrapped(row(record)) }, model.group_by_fields,
                           collision_check(model, bluebook, grouped_head))
                    elsif reduced_head && as == reduced_head[:as] && model.count?
                      value.length
                    elsif reduced_head && as == reduced_head[:as]
                      median(value, model.median_field)
                    elsif value.is_a?(Array)
                      value.map { |record| Value.materialize(row(record)) }
                    else
                      Value.materialize(row(value))
                    end
        end]
      end

      # Topologically sorts non-root heads by their declared reference fields
      # (Kahn's algorithm); a cycle falls back to declared order rather than looping.
      def order_other_heads(bluebook, root_heads, other_heads)
        resolved = root_heads.map { |head| head[:aggregate] }
        remaining = other_heads.dup
        ordered = []
        until remaining.empty?
          ready, blocked = remaining.partition do |head|
            depends_on(bluebook, head, other_heads).all? { |target| resolved.include?(target) }
          end
          if ready.empty?
            ordered.concat(remaining)
            break
          end
          ordered.concat(ready)
          resolved.concat(ready.map { |head| head[:aggregate] })
          remaining = blocked
        end
        ordered
      end

      # Which other declared heads a head's own aggregate holds a reference field
      # toward; an entity-headed include resolves no aggregate and so depends on nothing.
      def depends_on(bluebook, head, other_heads)
        aggregate = bluebook.aggregate(head[:aggregate])
        return [] unless aggregate

        other_heads.reject { |other| other[:aggregate] == head[:aggregate] }
                   .select { |other| reference_fields(aggregate, other[:aggregate]).any? }
                   .map { |other| other[:aggregate] }
      end

      # Resolves `group_by`'s target head and validates its fields once, raising on
      # a typo'd field name rather than silently grouping every row under `nil`.
      def group_by_target(model, bluebook)
        return nil unless model.group_by.any?

        target = model.aggregate_heads.find { |head| head[:many] }
        aggregate = bluebook.aggregate(target[:aggregate])
        model.group_by_fields.each do |field|
          next if aggregate.attribute(field)
          # A lifecycle field is a real field too — it's stored on the record like
          # any attribute, just declared via `lifecycle :status`, and it's usually
          # exactly the field a report wants to group by.
          next if aggregate.lifecycle && aggregate.lifecycle.field.to_sym == field.to_sym

          raise ArgumentError,
                "#{model.name}'s group_by names #{field.inspect}, but #{target[:aggregate]} " \
                "declares no such attribute (it declares #{aggregate.attributes.map(&:name).join(', ')})"
        end
        target
      end

      # Whether `group_by` leaves must hold one row, decided from the declaration
      # alone (ADR 0061 D1): nil when the key path already covers the identity.
      def collision_check(model, bluebook, grouped_head)
        model.groups_by_identity?(bluebook.aggregate(grouped_head[:aggregate])) ? nil : model
      end

      # Nests one level per `group_by` field; a leaf holding more than one row
      # is a `group_by` collision (ADR 0061 D1), refused rather than picking one.
      def nest(rows, fields, checked, reached = [])
        field, *rest = fields
        rows.group_by { |row| row[field] }.to_h do |key, group|
          # Strip only the field just grouped by, not the whole remaining
          # list — `rest`'s own fields have to survive into the recursive
          # call below, or the next level groups by a key that's already gone.
          stripped = group.map { |row| row.reject { |name, _| name == field } }
          path = reached + [[field, key]]
          [key, rest.empty? ? leaf(stripped, checked, path) : nest(stripped, rest, checked, path)]
        end
      end

      def leaf(rows, checked, path)
        return rows.first unless checked && rows.size > 1

        raise InvariantViolation,
              RefusalWording.render_site("InvariantViolation", "group_by_collision",
                                         read_model: checked.name, fields: checked.group_by_fields,
                                         ids: rows.map { |row| row[:id] },
                                         key: path.map { |field, value| "#{field} = #{value}" }.join(", "))
      end

      # Resolves `count`/`median`'s single many-side head, raising on a `median`
      # field that doesn't exist or isn't numeric rather than comparing garbage.
      def aggregation_target(model, bluebook)
        return nil unless model.count? || model.median_field

        target = model.aggregate_heads.find { |head| head[:many] }
        return target unless model.median_field

        aggregate = bluebook.aggregate(target[:aggregate])
        attribute = aggregate.attribute(model.median_field)
        unless attribute
          raise ArgumentError,
                "#{model.name}'s median names #{model.median_field.inspect}, but #{target[:aggregate]} " \
                "declares no such attribute (it declares #{aggregate.attributes.map(&:name).join(', ')})"
        end
        unless QuerySpecification::FieldPath.numeric?(attribute, []) { |type| aggregate.value_object(type) }
          raise ArgumentError,
                "#{model.name}'s median names #{model.median_field.inspect} on #{target[:aggregate]}, " \
                "which is not numeric — median needs a numeric field (a bare number, or a " \
                "value object carrying one)"
        end
        target
      end

      # The standard median: middle value when odd, average of the two middle
      # values when even; an empty collection has no median (nil, not zero).
      def median(rows, field)
        values = rows.map { |record| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row(record), field)) }
                     .compact.sort
        return nil if values.empty?

        middle = values.length / 2
        values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
      end

      def fetch(bluebook, domain, aggregate_name, id)
        @registry.read_repository(domain, bluebook.aggregate(aggregate_name)).find(id) ||
          raise(NotFound, RefusalWording.render_site("NotFound", "read_model_reference_missing",
                                                     aggregate: aggregate_name, offered: Rendering.describe(id)))
      end

      def records(bluebook, domain, aggregate_name)
        aggregate = bluebook.aggregate(aggregate_name)
        aggregate ? @registry.read_repository(domain, aggregate).all : []
      end

      # A reference has no path of its own (unlike an identity), so `Value.scalar`
      # refuses a composite rather than guessing which field was meant.
      def refuse_object_reference(model, args)
        offered = args.fetch(model.reference_name, nil)
        return unless offered.is_a?(Hash) || offered.is_a?(Value)

        raise TypeMismatch,
              RefusalWording.render_site("TypeMismatch", "read_model_object_reference",
                                         query: model.query_name, field: model.reference_name)
      end

      # A reference is the id, in the argument and in the stored row alike.
      def reference(value) = value.to_s

      def reference_fields(aggregate, target)
        aggregate.attributes
                 .select { |attribute| attribute.reference? && attribute.type.target_name == target.to_s }
                 .map(&:name)
      end

      def matching(records, &) = records.select(&).sort_by(&:id)
      def row(record) = record.to_h
    end
  end
end
