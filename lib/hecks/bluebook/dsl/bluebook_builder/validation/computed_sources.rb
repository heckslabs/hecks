module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks that every name and dotted path a computed `sets` source reads resolves, once
          # every aggregate and value object in the chapter exists.
          module ComputedSources
            private

            # Refuses a computed source whose operand path names nothing declared, runs through
            # a list or a reference, or ends on a value object with more than one field.
            def validate_computed_sources!(bluebook)
              value_objects = bluebook.aggregates.flat_map(&:value_objects).to_h { |vo| [vo.hecks_name.to_s, vo] }
              bluebook.aggregates.each do |aggregate|
                aggregate.commands.each { |command| check_computed_command!(aggregate, command, value_objects) }
              end
            end

            def check_computed_command!(aggregate, command, value_objects)
              command.mutations.select { |mutation| mutation.source.is_a?(Computed) }.each do |mutation|
                operand_paths(Expression::Resolver.parse(mutation.source.text)).each do |path|
                  check_operand_path!(PathCheck.new(aggregate, command, mutation, value_objects), path)
                end
              end
            end

            # Where a path is read: the aggregate and command it belongs to, the mutation, and the
            # chapter's value objects by name.
            PathCheck = Struct.new(:aggregate, :command, :mutation, :value_objects) do
              # @param name [String] a path's first segment
              # @return [Bluebook::Attribute, nil] the command's argument by that name, else the
              #   owner's field, else `nil`
              def operand_head(name)
                command.attributes.find { |attr| attr.name.to_s == name } ||
                  aggregate.attributes.find { |attr| attr.name.to_s == name }
              end

              # A lifecycle or projected field is a plain scalar of the record.
              #
              # @param name [String] a path's first segment
              # @return [Boolean] whether `name` is the owner's lifecycle or a projected field
              def stored_scalar?(name)
                aggregate.lifecycle_field.to_s == name || aggregate.projected_fields.any? { |f| f.name.to_s == name }
              end

              # @return [String] how a refusal names the source: `Owner.Command's sets :target`
              def site = "#{aggregate.hecks_name}.#{command.hecks_name}'s sets :#{mutation.target}"
            end
            private_constant :PathCheck

            def operand_paths(node)
              return [node.path] if node.is_a?(Expression::Resolver::Lookup)
              return [] unless node.is_a?(Struct)

              node.members.flat_map { |member| operand_paths(node[member]) }
            end

            def check_operand_path!(check, path)
              head, *segments = path.split(".")
              attribute = check.operand_head(head)
              return if attribute.nil? && segments.empty? && check.stored_scalar?(head)

              owner = check.aggregate
              refuse_operand!(check, path, "names no argument or field of #{owner.hecks_name}") unless attribute
              walk_operand_path!(check, path, attribute, segments)
            end

            def walk_operand_path!(check, path, attribute, segments)
              segments.each do |segment|
                refuse_operand!(check, path, "runs through #{attribute.name}, which is a list") if attribute.list?
                refuse_operand!(check, path, "runs through #{attribute.name}, which is a reference") if attribute.reference?
                attribute = field_of(check, path, attribute, segment)
              end
              refuse_operand!(check, path, "is a list") if attribute.list?
              refuse_operand!(check, path, "is a reference") if attribute.reference?
              refuse_multi_field!(check, path, attribute)
            end

            def field_of(check, path, attribute, segment)
              holder = check.value_objects[attribute.type.to_s]
              refuse_operand!(check, path, "runs through #{attribute.name}, which is not a value object") unless holder
              holder.attributes.find { |field| field.name.to_s == segment } ||
                refuse_operand!(check, path, "names #{segment}, which #{holder.hecks_name} does not declare")
            end

            # A name that stops on a value object reads as its one field, so it needs exactly one.
            def refuse_multi_field!(check, path, attribute)
              holder = check.value_objects[attribute.type.to_s]
              return unless holder && holder.attributes.size > 1

              example = "#{path}.#{holder.attributes.first.name}"
              refuse_operand!(check, path, "is a #{holder.hecks_name} with several fields — name one, as #{example}")
            end

            def refuse_operand!(check, path, reason)
              raise Malformed, "#{check.site} reads #{path}, which #{reason}"
            end
          end
        end
      end
    end
  end
end
