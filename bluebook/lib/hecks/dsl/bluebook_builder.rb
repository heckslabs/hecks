module Hecks
  module DSL

    # Hecks::DSL::BluebookBuilder
    #
    # Top-level DSL builder for composing multiple domains (chapters) into a
    # single Bluebook. Each chapter block delegates to DomainBuilder, producing
    # a standard Domain IR. The resulting BluebookStructure holds all chapters.
    #
    #   Hecks.bluebook "PizzaShop" do
    #     chapter "Pizzas" do
    #       aggregate "Pizza" do
    #         attribute :name, String
    #       end
    #     end
    #
    #     chapter "Billing" do
    #       aggregate "Invoice" do
    #         attribute :amount, Float
    #       end
    #     end
    #   end
    #
    class BluebookBuilder
      Structure = DomainModel::Structure

      # @param name [String] the bluebook/system name
      # @param version [String, nil] optional version
      def initialize(name, version: nil)
        @name = name
        @version = version
        @binding_builder = nil
        @chapters = []
      end

      # Define a chapter (domain) within this bluebook.
      #
      # The block is evaluated inside a DomainBuilder — all standard domain
      # DSL methods (aggregate, policy, service, etc.) are available.
      #
      # @param name [String] the chapter/domain name
      # @param version [String, nil] optional chapter version
      # @yield block evaluated in the context of DomainBuilder
      # @return [void]
      # @raise [ArgumentError] if a chapter with the same name already exists
      # Define the binding (spine) for this bluebook.
      #
      # @param name [String] the binding domain name
      # @yield block evaluated in the context of DomainBuilder
      def binding(name = "Binding", &block)
        builder = DomainBuilder.new(name)
        builder.instance_eval(&block) if block
        @binding_builder = builder
      end

      def chapter(name, version: nil, &block)
        if @chapters.any? { |ch| ch[:name] == name }
          raise ArgumentError, "Duplicate chapter name: #{name}"
        end
        builder = DomainBuilder.new(name, version: version)
        builder.instance_eval(&block) if block
        @chapters << { name: name, builder: builder }
      end

      # Build the BluebookStructure IR from all collected chapters.
      #
      # @return [DomainModel::Structure::BluebookStructure]
      def build
        binding_domain = @binding_builder&.build
        domains = @chapters.map { |ch| ch[:builder].build }
        Structure::BluebookStructure.new(
          name: @name,
          binding: binding_domain,
          chapters: domains,
          version: @version
        )
      end
    end
  end
end
