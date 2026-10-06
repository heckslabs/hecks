module Hecks
  module Bluebook
    module DSL
      module AttributeCollector
        # Expands an `identified_by` declaration into the scalar paths that make up an identity:
        # a named attribute, or a value object minted as one structured field, walked down to
        # its scalar leaves.
        module IdentityResolution
          private

          # Each selected identity head contributes all its scalar leaves in declaration order.
          def resolve_identity_field!(field, value_objects, context_name)
            attr = attributes.find { |a| a.name == field }

            # A bare `:id` or `_id`-suffixed name with no matching attribute is the walk-parent/
            # fallback-identity convention (Instance#materialize_identity! falls back to `:id`).
            return [field.to_s] if attr.nil? && (field.to_s == "id" || field.to_s.end_with?("_id"))

            raise Malformed, "#{context_name}.identified_by :#{field} names no attribute #{context_name} declares" unless attr

            identity_paths_for_attribute(attr, value_objects, context_name, field.to_s, [])
          end

          # A named or inline identity mints one structured field, then expands
          # each scalar leaf beneath it into the existing path-shaped IR.
          def resolve_identity_type!(type, as, insert_at, value_objects, context_name)
            target = Naming.demodulise(type.respond_to?(:hecks_name) ? type.hecks_name : type)
            vo = identity_value_object(type, target, value_objects, context_name)
            field = (as || Naming.snake(target)).to_sym
            refuse_declared_identity_field!(field, target, context_name)

            insert_identity_attribute(field, target, insert_at)
            vo.attributes.flat_map do |attribute|
              identity_paths_for_attribute(attribute, value_objects, context_name,
                                           "#{field}.#{attribute.name}", [target])
            end
          end

          def identity_value_object(type, target, value_objects, context_name)
            matches = value_objects.select { |value_object| value_object.hecks_name.to_s == target }
            raise Malformed, "#{context_name}.identified_by names duplicate value object #{target}" if matches.size > 1

            vo = type.respond_to?(:attributes) ? type : matches.first
            raise Malformed, "#{context_name}.identified_by names #{target}, which is not a declared value object" unless vo
            raise Malformed, "#{context_name}.identified_by names #{target}, which declares no attributes" if vo.attributes.empty?

            vo
          end

          def refuse_declared_identity_field!(field, target, context_name)
            return unless attributes.any? { |attribute| attribute.name == field }

            raise Malformed,
                  "#{context_name}.identified_by #{target} mints :#{field}, but that attribute is already declared"
          end

          # `Attribute.new` directly: the value object is an anonymous class whose `to_s` would
          # spell "#<Class:0x...>", so the demodulised `target` text is the type. The attribute
          # is moved to `insert_at`, the attribute count when `identified_by` was called;
          # resolution runs at build time, so appending would put the identity field last.
          def insert_identity_attribute(field, target, insert_at)
            attributes << Attribute.new(name: field, type: target)
            attributes.insert(insert_at, attributes.pop)
          end

          def identity_paths_for_attribute(attribute, value_objects, context_name, path, visited)
            refuse_unfit_identity_member!(attribute, context_name, path)
            return [path] if attribute.reference?

            nested = value_objects.find { |value_object| value_object.hecks_name.to_s == attribute.type.to_s }
            return [path] unless nested

            refuse_identity_cycle!(nested, visited, context_name)
            refuse_compound_identity!(nested, path, context_name)

            member = nested.attributes.first
            identity_paths_for_attribute(member, value_objects, context_name, "#{path}.#{member.name}",
                                         [*visited, nested.hecks_name.to_s])
          end

          def refuse_unfit_identity_member!(attribute, context_name, path)
            if attribute.list?
              raise Malformed,
                    "#{context_name}'s identity member #{path} is a list — an identity member must be scalar"
            end
            return unless attribute.optional?

            raise Malformed,
                  "#{context_name}'s identity member #{path} is optional — an identity must be wholly known"
          end

          def refuse_identity_cycle!(nested, visited, context_name)
            return unless visited.include?(nested.hecks_name.to_s)

            cycle = [*visited, nested.hecks_name.to_s].join(" -> ")
            raise Malformed, "#{context_name}'s identity value objects form a cycle: #{cycle}"
          end

          # A bare field derives one scalar, so each value object on the way must wrap exactly one
          # field (ADR 0025); otherwise it would silently mint an unannounced compound key.
          def refuse_compound_identity!(nested, path, context_name)
            return if nested.attributes.size == 1

            candidates = nested.attributes.map(&:name).join(", ")
            raise Malformed,
                  "#{context_name}.identified_by :#{path} names #{nested.hecks_name}, which has " \
                  "#{nested.attributes.size} field#{"s" unless nested.attributes.size == 1} (#{candidates})"
          end
        end
      end
    end
  end
end
