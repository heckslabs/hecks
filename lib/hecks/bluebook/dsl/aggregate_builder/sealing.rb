require_relative "query_sealing"
require_relative "correction_sealing"

module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # Build-time checks that what a command, default, or projection names exists on the
        # aggregate. Included into AggregateBuilder; `#build` runs them once every declaration is in
        # place. Query checks live in `QuerySealing`, correction checks in `CorrectionSealing`.
        module Sealing
          include QuerySealing
          include CorrectionSealing

          private

          def seal_all
            seal_mutation_targets
            seal_query_targets
            seal_defaults
            seal_lifecycle_guards
            seal_projected_fields
            seal_correction_targets
          end

          # Tells every reference which aggregate declares it, so it can resolve its target.
          #
          # Stamped at build because a command builder does not hold the aggregate. Walks every
          # list that can carry a reference: a missed one resolves to nil and is silently skipped.
          def stamp_references(aggregate)
            reference_bearing_attributes.each { |attribute| attribute.type.declared_in = aggregate }
          end

          # An owned piece's `reference_to` is an edge the aggregate points across too, so a ring
          # through a contained piece is refused like a direct aggregate-to-aggregate ring.
          # Command/query reference arguments are excluded: they are dispatch data, not state.
          def entity_reference_targets
            @entities.flat_map { |entity| entity.attributes.select(&:reference?).map { |a| a.type.target_name.to_s } }
          end

          def reference_bearing_attributes
            lists = [attributes, *@commands.map(&:attributes), *@queries.map(&:attributes)]
            @entities.each do |entity|
              lists << entity.attributes
              lists.concat(entity.commands.map(&:attributes))
              lists.concat(entity.queries.map(&:attributes))
            end

            lists.flatten.select(&:reference?)
          end

          # A default fills the shape it is declared on, or it fills nothing.
          #
          # A bare default on a value-object attribute builds cleanly and then refuses every
          # create at dispatch. A Hash default is left to `Value.for_attribute`.
          def seal_defaults
            # closed_sets too: an inline `one_of(...)` lives there until `#build` merges it.
            shapes = (@value_objects + closed_sets).map { |shape| shape.hecks_name.to_s }

            attributes.each do |attribute|
              next if attribute.default.nil? || attribute.default.is_a?(Hash)

              refuse_bare_shape_default!(attribute) if shapes.include?(attribute.type.to_s)
            end
          end

          def refuse_bare_shape_default!(attribute)
            raise Malformed,
                  "#{@name}.#{attribute.name} defaults to #{attribute.default.inspect}, but " \
                  "#{attribute.type} is a value object — a default fills its FIELDS " \
                  "(default: { ... }), and a bare value refuses every create instead"
          end

          # A command's `from:` guard needs a lifecycle field to check against.
          def seal_lifecycle_guards
            return if @lifecycle

            @commands.each do |command|
              next unless command.from

              raise Malformed,
                    "#{@name}.#{command.hecks_name} guards from: #{Array(command.from).inspect}, but " \
                    "#{@name} declares no lifecycle — from: checks a lifecycle field, and there is " \
                    "none here to check"
            end
          end

          # The local half of `projects` resolution: `reference` must name a reference attribute
          # here and `name` must not collide with a declared attribute. The target aggregate's
          # field is checked later by BluebookBuilder, once the whole chapter exists.
          def seal_projected_fields
            declared = attributes.map { |attribute| attribute.name.to_sym }

            @projected_fields.each do |field|
              refuse_shadowing_projection!(field) if declared.include?(field.name)
              refuse_projection_through_non_reference!(field)
            end
          end

          def refuse_shadowing_projection!(field)
            raise Malformed,
                  "#{@name}.projects :#{field.name} names a field #{@name} already declares — " \
                  "a projected field is never a second spelling of one that already exists"
          end

          def refuse_projection_through_non_reference!(field)
            reference_attribute = attributes.find { |attribute| attribute.name == field.reference }
            return if reference_attribute&.reference?

            raise Malformed,
                  "#{@name}.projects :#{field.name} reads through #{field.reference.inspect}, which " \
                  "#{@name} never declares as a reference_to — projects reads through a REFERENCE, " \
                  "never a value object or a scalar"
          end

          # A mutation must name a field the aggregate actually has.
          #
          # Lives here, not in the language: a command's changes and the aggregate's fields hang
          # off different roots, and a given is a closed predicate over its own state.
          def seal_mutation_targets
            known = attributes.map { |attribute| attribute.name.to_sym }
            known << @lifecycle.field.to_sym if @lifecycle

            @commands.each do |command|
              command.mutations.each { |mutation| seal_mutation_target(command, mutation, known) }
            end
          end

          def seal_mutation_target(command, mutation, known)
            # :delegate targets an "Entity.Command" pair and :corrects an event name, not a
            # field; the latter is checked by `seal_correction_targets`.
            return if [:delegate, :corrects].include?(mutation.op)

            refuse_lifecycle_field_write!(command, mutation)
            return if known.include?(mutation.target.to_sym)

            raise Malformed,
                  "#{@name}.#{command.hecks_name} sets #{mutation.target}, which #{@name} " \
                  "never declares — a mutation into a field that does not exist " \
                  "writes nothing and refuses nothing"
          end

          # The lifecycle field moves only by transition (C5.3). Frozen era text is exempt
          # (`MetaValidator.shadow_parsing?`) so it keeps parsing.
          def refuse_lifecycle_field_write!(command, mutation)
            return unless @lifecycle && mutation.target.to_sym == @lifecycle.field.to_sym
            return if MetaValidator.shadow_parsing?

            raise Malformed,
                  "#{@name}.#{command.hecks_name} sets #{mutation.target}, #{@name}'s lifecycle field — " \
                  "a lifecycle field moves only by transition; declare one instead of setting it"
          end
        end
      end
    end
  end
end
