  # Hecks::GateEnforcer
  #
  # Applies gate-based access restrictions to an aggregate class.
  # Gates are defined in the Hecksagon (infrastructure wiring), not in
  # the domain DSL. For each method not allowed by the gate, redefines
  # it to raise Hecks::GateAccessDenied.
  #
  # When no gate is specified, all methods remain accessible.
  #

module Hecks
  # Hecks::GateEnforcer
  #
  # Applies gate-based access restrictions to aggregate classes, raising GateAccessDenied for blocked methods.
  #
  class GateEnforcer
    include HecksTemplating::NamingHelpers
      CLASS_METHODS    = %i[find all count delete where first last create].freeze
      INSTANCE_METHODS = %i[save destroy update].freeze

      # @param gate_name [Symbol, nil] the role to enforce, or nil to skip
      # @param hecksagon [Hecksagon::Structure::Hecksagon, nil] the infrastructure IR
      def initialize(gate_name:, hecksagon: nil)
        @gate_name = gate_name
        @hecksagon = hecksagon
      end

      # Enforces gate restrictions on the given aggregate class.
      #
      # Looks up the gate from the Hecksagon IR for this aggregate + role,
      # then restricts disallowed methods.
      #
      # @param agg [Hecks::DomainModel::Aggregate] the aggregate definition
      # @param agg_class [Class] the runtime aggregate class to restrict
      # @return [void]
      def enforce!(agg, agg_class)
        return unless @gate_name
        return unless @hecksagon

        gate_def = @hecksagon.gate_for(agg.name, @gate_name)
        return unless gate_def

        restrict_class_methods(agg, agg_class, gate_def)
        restrict_instance_methods(agg, agg_class, gate_def)
      end

      private

      def restrict_class_methods(agg, agg_class, gate_def)
        gate_name = @gate_name
        agg_name = agg.name
        methods_to_check = CLASS_METHODS + command_method_names(agg)

        methods_to_check.each do |m|
          next if gate_def.allows?(m)
          next unless agg_class.respond_to?(m)
          agg_class.define_singleton_method(m) do |*args, **kwargs|
            raise Hecks::GateAccessDenied,
                  "#{agg_name}.#{m} is not allowed through the :#{gate_name} gate"
          end
        end
      end

      def restrict_instance_methods(agg, agg_class, gate_def)
        gate_name = @gate_name
        agg_name = agg.name

        INSTANCE_METHODS.each do |m|
          next if gate_def.allows?(m)
          agg_class.define_method(m) do |*args, **kwargs|
            raise Hecks::GateAccessDenied,
                  "#{agg_name}##{m} is not allowed through the :#{gate_name} gate"
          end
        end
      end

      def command_method_names(agg)
        agg.commands.map do |cmd|
          domain_command_method(cmd.name, agg.name)
        end
      end
  end
end
