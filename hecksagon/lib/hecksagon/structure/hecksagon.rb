module Hecksagon
  module Structure

    # Hecksagon::Structure::Hecksagon
    #
    # Intermediate representation of the hexagonal architecture wiring for a
    # domain. Holds gates (access control), adapter configuration, extensions,
    # cross-domain subscriptions, and tenancy strategy.
    #
    # Built by the Hecksagon DSL builder, consumed by the runtime boot sequence.
    #
    #   hex = Hecksagon.new(
    #     name: "Pizzas",
    #     gates: [GateDefinition.new(aggregate: "Pizza", role: :admin, allowed_methods: [:find])],
    #     adapter: { type: :sqlite, database: "app.db" },
    #     extensions: [{ name: :audit }],
    #     subscriptions: ["Billing"],
    #     tenancy: :row
    #   )
    #
    class Hecksagon
      attr_reader :name, :gates, :adapter, :extensions, :subscriptions, :tenancy,
                  :capabilities, :aggregate_capabilities

      def initialize(name:, gates: [], adapter: nil, extensions: [], subscriptions: [],
                     tenancy: nil, capabilities: [], aggregate_capabilities: {})
        @name = name
        @gates = gates
        @adapter = adapter
        @extensions = extensions
        @subscriptions = subscriptions
        @tenancy = tenancy
        @capabilities = capabilities
        @aggregate_capabilities = aggregate_capabilities
      end

      # Returns gates for a specific aggregate.
      def gates_for(aggregate_name)
        @gates.select { |g| g.aggregate == aggregate_name.to_s }
      end

      # Returns the gate for a specific aggregate + role combination.
      def gate_for(aggregate_name, role)
        @gates.find { |g| g.aggregate == aggregate_name.to_s && g.role == role.to_sym }
      end
    end
  end
end
