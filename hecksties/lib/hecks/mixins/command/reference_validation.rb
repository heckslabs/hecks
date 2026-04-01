# Hecks::Command::ReferenceValidation
#
# Validates reference_to fields on a command before execution to prevent IDOR
# (Insecure Direct Object Reference) attacks. For each reference declared on
# the command's class, resolves the target aggregate class, looks up the
# supplied ID, and optionally calls the reference_authorizer proc.
#
# Validation modes (set via `validate:` on `reference_to`):
#   true       — check existence + run reference_authorizer if set (default)
#   :exists    — check existence only, skip authorization
#   false      — skip all validation (opt-out for eventual consistency)
#
# nil values are always skipped (nullable references).
#
# == Usage
#
#   class PlaceOrder
#     include Hecks::Command
#     # reference_meta and reference_authorizer are set by command_methods.rb at boot
#   end
#
module Hecks
  module Command
    module ReferenceValidation
      # Validates all reference fields on this command instance.
      # Called by ValidateReferencesStep in the lifecycle pipeline.
      #
      # @return [void]
      # @raise [Hecks::ReferenceNotFound] if a referenced aggregate cannot be found
      # @raise [Hecks::ReferenceAccessDenied] if the reference_authorizer denies access
      def validate_references
        meta = self.class.reference_meta
        return unless meta&.any?

        authorizer = self.class.reference_authorizer

        meta.each do |ref|
          next if ref.validate == false

          val = respond_to?(ref.name, true) ? send(ref.name) : nil
          next if val.nil?

          target_class = resolve_reference_class(ref)
          next unless target_class

          record = target_class.find(val)
          if record.nil?
            raise Hecks::ReferenceNotFound.new(
              "#{ref.type} '#{val}' not found",
              reference_type: ref.type,
              reference_id: val
            )
          end

          next if ref.validate == :exists
          next unless authorizer

          unless authorizer.call(ref, record, self)
            raise Hecks::ReferenceAccessDenied.new(
              "Access denied to #{ref.type} '#{val}'",
              reference_type: ref.type,
              reference_id: val,
              actor: self.class.respond_to?(:actor) ? self.class.actor : nil
            )
          end
        end
      end

      private

      # Resolves the Ruby class for a reference from the command's domain module.
      # For cross-domain references (ref.domain non-nil), resolves from the
      # foreign domain's constant (e.g., BillingDomain::Invoice).
      #
      # @param ref [Hecks::DomainModel::Structure::Reference] the reference IR node
      # @return [Class, nil] the resolved aggregate class, or nil if unresolvable
      def resolve_reference_class(ref)
        if ref.domain
          foreign_mod = "#{ref.domain}Domain"
          begin
            Object.const_get(foreign_mod).const_get(ref.type)
          rescue NameError
            nil
          end
        else
          domain_mod = self.class.name.split("::")[0..-4].join("::")
          mod = domain_mod.empty? ? Object : Object.const_get(domain_mod)
          begin
            mod.const_get(ref.type)
          rescue NameError
            nil
          end
        end
      end
    end
  end
end
