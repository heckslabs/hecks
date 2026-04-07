module Hecks
  module DomainModel
    module Behavior

      # Hecks::DomainModel::Behavior::Service
      #
      # Intermediate representation of a domain service -- a stateless operation that
      # orchestrates multiple commands across aggregates. Services have input attributes
      # and a call body (the orchestration logic) that dispatches commands to one or
      # more aggregates.
      #
      # Unlike commands, which operate on a single aggregate, services coordinate
      # cross-aggregate workflows that don't naturally belong to any one aggregate.
      #
      # Part of the DomainModel IR layer. Built by ServiceBuilder in the DSL,
      # consumed by ServiceGenerator to produce service classes in the domain gem.
      #
      #   svc = Service.new(
      #     name: "TransferMoney",
      #     attributes: [Attribute.new(name: :amount, type: Integer)],
      #     call_body: proc { |attrs| dispatch(:Debit, attrs); dispatch(:Credit, attrs) }
      #   )
      #   svc.name       # => "TransferMoney"
      #   svc.attributes # => [#<Attribute name=:amount>]
      #
      class Service
        # @return [String] PascalCase service name (e.g. "TransferMoney")
        # @return [Array<Hecks::DomainModel::Structure::Attribute>] input attributes
        #   required to invoke this service
        # @return [Proc, nil] the orchestration body that dispatches commands;
        #   nil if the service has no inline implementation
        attr_reader :name, :attributes, :coordinates, :call_body, :description

        def initialize(name:, attributes: [], coordinates: [], call_body: nil, description: nil)
          @name = name
          @attributes = attributes
          @coordinates = coordinates
          @call_body = call_body
          @description = description
        end
      end
    end
  end
end
