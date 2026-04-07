module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::ReadModel
    #
    # Represents a read model (data view) needed by a command to make decisions.
    # Captured during Event Storming as green stickies -- the information a user
    # needs to see before issuing a command.
    #
    # Read models are the "what do I need to know?" artifacts from Event Storming.
    # They document the data views or screens that inform user decisions. For example,
    # a "Menu & Availability" read model tells the domain that users need to see
    # available menu items before placing an order.
    #
    # Part of the DomainModel IR layer. Does not generate code -- serves as
    # metadata for documentation, UI planning, and domain understanding.
    #
    #   read_model = ReadModel.new(name: "Menu & Availability")
    #   read_model.name  # => "Menu & Availability"
    #
    class ReadModel
      # @return [String] the name of this read model, describing the data view
      #   (e.g., "Menu & Availability", "Order History", "Account Dashboard")
      attr_reader :name

      # Creates a new ReadModel.
      #
      # @param name [String] the human-readable name describing this data view.
      #   Should convey what information the user needs to see.
      #
      # @return [ReadModel] a new ReadModel instance
      def initialize(name:)
        @name = name
      end
    end
    end
  end
end
