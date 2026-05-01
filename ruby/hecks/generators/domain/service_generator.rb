module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::ServiceGenerator
    #
    # Generates domain service classes that orchestrate commands across
    # aggregates. Each service has attributes, a +call+ method whose body
    # comes from the DSL block, and returns +self+ with results attached.
    # Services are namespaced under +Domain::Services+.
    #
    # Domain services are used when a business operation spans multiple
    # aggregates or requires coordination logic that does not belong to
    # a single aggregate.
    #
    # Part of Generators::Domain.
    #
    # == Usage
    #
    #   gen = ServiceGenerator.new(service, domain_module: "ModelRegistryDomain")
    #   gen.generate
    #
    class ServiceGenerator

      # Initializes the service generator.
      #
      # @param service [Object] the service model object; provides +name+, +attributes+,
      #   and +call_body+ (a Proc whose source becomes the call method body)
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      def initialize(service, domain_module:)
        @service = service
        @domain_module = domain_module
      end

      # Generates the full Ruby source code for the domain service class.
      #
      # Produces a class under +Domain::Services+ with:
      # - +attr_reader+ for all service attributes plus +:results+
      # - An +initialize+ method accepting keyword arguments for each attribute
      # - A +call+ method whose body comes from the DSL block, returning +self+
      #
      # If the service has no attributes, the constructor takes no arguments
      # and only initializes +@results+.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  module Services"
        lines << "    class #{@service.name}"
        attrs = @service.attributes
        unless attrs.empty?
          lines << "      attr_reader #{attrs.map { |a| ":#{a.name}" }.join(', ')}, :results"
          lines << ""
          params = attrs.map { |a| "#{a.name}:" }.join(", ")
          lines << "      def initialize(#{params})"
          attrs.each { |a| lines << "        @#{a.name} = #{a.name}" }
          lines << "        @results = []"
          lines << "      end"
        else
          lines << "      attr_reader :results"
          lines << ""
          lines << "      def initialize"
          lines << "        @results = []"
          lines << "      end"
        end
        lines << ""
        lines << "      def call"
        lines << "        #{call_body}"
        lines << "        self"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Extracts the source code from the service's DSL block.
      #
      # @return [String] the block's source code as a string
      def call_body
        Hecks::Utils.block_source(@service.call_body)
      end
    end
    end
  end
end
