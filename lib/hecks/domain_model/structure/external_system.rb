module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::ExternalSystem
    #
    # Represents an external system that a command interacts with. Captured
    # during Event Storming as pink stickies -- third-party services, APIs,
    # or legacy systems outside the domain boundary.
    #
    # External systems are integration points that the domain depends on but
    # does not control. They inform documentation, architecture diagrams,
    # and integration planning. Examples include payment gateways (Stripe),
    # email services (SendGrid), or legacy ERP systems.
    #
    # Part of the DomainModel IR layer. Does not generate code -- serves as
    # metadata for documentation and integration planning.
    #
    #   external = ExternalSystem.new(name: "Stripe")
    #   external.name  # => "Stripe"
    #
    class ExternalSystem
      # @return [String] the name of the external system (e.g., "Stripe", "SendGrid", "Legacy ERP")
      attr_reader :name

      # Creates a new ExternalSystem.
      #
      # @param name [String] the human-readable name of the external system.
      #   Should identify the third-party service or legacy system that the
      #   domain interacts with.
      #
      # @return [ExternalSystem] a new ExternalSystem instance
      def initialize(name:)
        @name = name
      end
    end
    end
  end
end
