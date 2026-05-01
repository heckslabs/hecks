module Hecksagon
  module DSL

    # Hecksagon::DSL::GateBuilder
    #
    # DSL builder for gate (access control) declarations. Collects allowed
    # methods for a specific aggregate + role combination and builds a
    # GateDefinition IR object.
    #
    #   builder = GateBuilder.new("Pizza", :admin)
    #   builder.allow :find, :all, :create_pizza
    #   gate = builder.build
    #
    class GateBuilder
      def initialize(aggregate, role)
        @aggregate = aggregate
        @role = role
        @allowed_methods = []
        @ownership_field = nil
      end

      # Declare one or more methods as allowed through this gate.
      #
      # @param methods [Array<Symbol>] allowed method names
      # @return [void]
      def allow(*methods)
        @allowed_methods.concat(methods.map(&:to_sym))
      end

      # Declare which aggregate attribute identifies the record owner.
      #
      # When set, find/all/delete operations will be scoped to the current
      # user (from +Hecks.current_user+). find and delete raise
      # +Hecks::GateAccessDenied+ if the record is owned by someone else.
      # +all+ filters to only owned records.
      #
      # @param field [Symbol] the attribute name holding the owner identity
      # @return [void]
      def owned_by(field)
        @ownership_field = field.to_sym
      end

      # Build and return the GateDefinition IR object.
      #
      # @return [Hecksagon::Structure::GateDefinition]
      def build
        Structure::GateDefinition.new(
          aggregate: @aggregate,
          role: @role,
          allowed_methods: @allowed_methods,
          ownership_field: @ownership_field
        )
      end
    end
  end
end
