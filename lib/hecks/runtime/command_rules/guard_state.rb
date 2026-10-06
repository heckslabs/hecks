require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class CommandRules
      module Admissibility
        # Wraps `subject` so a guard reads a declared, optional attribute
        # that predates the record as nil instead of raising.
        class GuardState
          def initialize(instance)
            @instance = instance
            @declared = instance.respond_to?(:aggregate) ? instance.aggregate.attributes.to_h { |a| [a.name, a] } : {}
            # Separate index: a projected field's absence raises its own
            # refusal, not AttributeAbsent's (ADR 0025).
            owner = instance.aggregate if instance.respond_to?(:aggregate)
            @projected = owner.respond_to?(:projected_fields) ? owner.projected_fields.to_h { |f| [f.name, f] } : {}
          end

          def key?(name) = @declared.key?(name.to_sym) || @projected.key?(name.to_sym) || @instance.key?(name)

          # Nil for an absent optional attribute; raises for anything else absent.
          def [](name)
            return @instance[name] if @instance.key?(name)

            projected = @projected[name.to_sym]
            return raise_projection_absent(projected) if projected

            attribute = @declared[name.to_sym]
            return nil if attribute.nil? || attribute.optional?

            raise AttributeAbsent,
                  RefusalWording.render_site("AttributeAbsent", "absent_read",
                                             aggregate: @instance.aggregate.hecks_name, field: name)
          end

          private

          def raise_projection_absent(projected)
            raise ProjectionAbsent,
                  RefusalWording.render_site("ProjectionAbsent", "absent_read",
                                             aggregate: @instance.aggregate.hecks_name, field: projected.name,
                                             reference: projected.reference, remote_field: projected.remote_field)
          end
        end
      end
    end
  end
end
