module Hecks
  module DSL

    # Hecks::DSL::ServiceBuilder
    #
    # DSL builder for domain service definitions. Services orchestrate
    # multiple commands across aggregates. The call block has access to
    # `dispatch(command_name, **attrs)` and the service's own attributes.
    #
    #   builder = ServiceBuilder.new("TransferMoney")
    #   builder.attribute :source_id, String
    #   builder.attribute :amount, Float
    #   builder.call { dispatch("Withdraw", account_id: source_id, amount: amount) }
    #   service = builder.build
    #
    # Builds a BluebookModel::Behavior::Service from DSL declarations.
    #
    # ServiceBuilder defines a domain service -- a stateless operation that
    # orchestrates multiple commands across different aggregates. Services
    # have input attributes (declared via AttributeCollector) and a call body
    # block that implements the orchestration logic.
    #
    # Within the call body, +dispatch(command_name, **attrs)+ is available
    # to issue commands, and the service's own attributes are accessible
    # as local methods.
    #
    # Includes AttributeCollector for the +attribute+, +list_of+, and
    # +reference_to+ DSL methods.
    class ServiceBuilder
      Behavior = BluebookModel::Behavior

      include AttributeCollector
      include Describable

      # Initialize a new service builder with the given service name.
      #
      # @param name [String] the service name (e.g. "TransferMoney", "ProcessRefund")
      def initialize(name)
        @name = name
        @attributes = []
        @coordinates = []
        @call_body = nil
      end

      # Declare which aggregates this service coordinates.
      #   coordinates "Account", "Ledger"
      def coordinates(*aggregates)
        @coordinates = aggregates.map(&:to_s)
      end

      # Set the call body block that implements the service's orchestration logic.
      #
      # The block is executed when the service is invoked at runtime. It has
      # access to the service's attributes and can dispatch commands to
      # multiple aggregates.
      #
      # @yield block implementing the service logic
      # @return [void]
      def call(&block)
        @call_body = block
      end

      # Build and return the BluebookModel::Behavior::Service IR object.
      #
      # @return [BluebookModel::Behavior::Service] the fully built service IR object
      def build
        Behavior::Service.new(
          name: @name,
          attributes: @attributes,
          coordinates: @coordinates,
          call_body: @call_body,
          description: @description
        )
      end
    end
  end
end
