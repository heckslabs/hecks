module Hecksagon
  module DSL

    # Hecksagon::DSL::PortContractBuilder
    #
    # Builds a port contract describing the shape an adapter must satisfy.
    # Collects required methods, accepted input types, and published event types.
    #
    #   builder = PortContractBuilder.new(:persistence)
    #   builder.requires :save, :find, :delete
    #   builder.accepts  "Pizza"
    #   builder.publishes "PizzaSaved"
    #   builder.build
    #   # => { name: :persistence, requires: [:save, :find, :delete],
    #   #      accepts: ["Pizza"], publishes: ["PizzaSaved"] }
    #
    class PortContractBuilder
      def initialize(name)
        @name = name.to_sym
        @required_methods = []
        @accepts = []
        @publishes = []
      end

      # Declare methods the adapter must implement.
      #
      # @param methods [Array<Symbol>] method names
      # @return [void]
      def requires(*methods)
        @required_methods.concat(methods.map(&:to_sym))
      end

      # Declare a type the port accepts as input.
      #
      # @param type [String] aggregate or value object name
      # @return [void]
      def accepts(type)
        @accepts << type.to_s
      end

      # Declare an event type the port publishes.
      #
      # @param type [String] event name
      # @return [void]
      def publishes(type)
        @publishes << type.to_s
      end

      # Build the port contract hash.
      #
      # @return [Hash] the port contract definition
      def build
        { name: @name, requires: @required_methods, accepts: @accepts, publishes: @publishes }
      end
    end
  end
end
