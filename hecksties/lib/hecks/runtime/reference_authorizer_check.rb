# Hecks::Runtime::ReferenceCoverageCheck
#
# Validates that domains declaring reference_to with validate: true (the default)
# on commands have a reference_authorizer registered. Raises +ConfigurationError+
# at boot when references need authorization checks but no authorizer is wired,
# preventing silent IDOR vulnerabilities.
#
#   # Automatically called after extensions fire during Hecks.boot
#   # To opt out, use validate: :exists or validate: false on the reference:
#   reference_to "Pizza", validate: :exists
#   reference_to "Pizza", validate: false
#
module Hecks
  class Runtime
    module ReferenceCoverageCheck
      # Scans the domain IR for commands with reference_to declarations that
      # require authorization (validate: true, the default) and verifies that
      # reference_authorizer is set on the corresponding command class.
      #
      # Raises +Hecks::ConfigurationError+ if authorization-required references
      # exist but no reference_authorizer is registered on the command class.
      #
      # @return [void]
      # @raise [Hecks::ConfigurationError] when auth-required references have no authorizer
      def check_reference_coverage!
        unprotected = unprotected_reference_commands
        return if unprotected.empty?

        names = unprotected.map { |agg, cmd| "#{agg.name}##{cmd.name}" }.join(", ")
        count = unprotected.size
        raise Hecks::ConfigurationError,
          "Domain '#{@domain.name}' declares reference_to with validate: true on " \
          "#{count} command#{'s' unless count == 1} (#{names}) but no " \
          "reference_authorizer is registered. Set reference_authorizer on the " \
          "command class, or use validate: :exists or validate: false to opt out."
      end

      private

      # Collects all [aggregate, command] pairs where a command has at least one
      # reference_to with validate: true and no reference_authorizer set.
      #
      # @return [Array<[DomainModel::Structure::Aggregate, DomainModel::Behavior::Command]>]
      def unprotected_reference_commands
        @domain.aggregates.flat_map do |agg|
          agg.commands.select do |cmd|
            has_auth_required_reference?(cmd) && !authorizer_set?(agg, cmd)
          end.map { |cmd| [agg, cmd] }
        end
      end

      # Returns true if the command has at least one reference with validate: true.
      #
      # @param cmd [DomainModel::Behavior::Command]
      # @return [Boolean]
      def has_auth_required_reference?(cmd)
        cmd.references.any? { |ref| ref.validate == true }
      end

      # Returns true if the resolved command class has a reference_authorizer set.
      #
      # @param agg [DomainModel::Structure::Aggregate]
      # @param cmd [DomainModel::Behavior::Command]
      # @return [Boolean]
      def authorizer_set?(agg, cmd)
        cmd_class = resolve_command_class(agg, cmd)
        return false unless cmd_class
        !cmd_class.reference_authorizer.nil?
      end

      # Resolves the Ruby command class from the domain module for a given
      # aggregate/command pair.
      #
      # @param agg [DomainModel::Structure::Aggregate]
      # @param cmd [DomainModel::Behavior::Command]
      # @return [Class, nil]
      def resolve_command_class(agg, cmd)
        Hecks::Conventions::Names.resolve_command_const(@mod, agg.name, cmd.name)
      rescue NameError
        nil
      end
    end
  end
end
