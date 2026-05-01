module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::MemoryAdapterGenerator
    #
    # Generates in-memory repository implementations that store aggregates in a
    # hash. Every aggregate gets one by default -- zero setup needed. Includes a
    # query method for adapter-driven filtering, sorting, and pagination. Part of
    # Generators::Infrastructure, consumed by DomainGemGenerator and InMemoryLoader.
    #
    #   gen = MemoryAdapterGenerator.new(agg, domain_module: "PizzasDomain")
    #   gen.generate  # => "module PizzasDomain\n  module Adapters\n    class PizzaMemoryRepository\n  ..."
    #
    class MemoryAdapterGenerator < Hecks::Generator

      # Creates a new MemoryAdapterGenerator for a single aggregate.
      #
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      #   that needs an in-memory repository
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(aggregate, domain_module:, mixin_prefix: "Hecks")
        @aggregate = aggregate
        @domain_module = domain_module
        @mixin_prefix = mixin_prefix
        @safe_name = bluebook_constant_name(@aggregate.name)
      end

      # Generates Ruby source for an in-memory repository adapter class.
      #
      # The generated class:
      # - Includes the corresponding port module (+Ports::<Agg>Repository+)
      # - Stores aggregates in a +@store+ hash keyed by ID
      # - Implements +find(id)+, +save(agg)+, +delete(id)+, +all+, +count+, +clear+
      # - Provides a +query+ method supporting +conditions+ (hash or Operator objects),
      #   +order_key+/+order_direction+, +limit+, and +offset+
      #
      # @return [String] the complete Ruby source code for the adapter class
      def generate
        snake = bluebook_snake_name(@safe_name)
        port_path = "Ports::#{@safe_name}Repository"

        lines = []
        lines << "module #{@domain_module}"
        lines << "  module Adapters"
        lines << "    class #{@safe_name}MemoryRepository"
        lines << "      include #{port_path}"
        lines << ""
        lines << "      def initialize"
        lines << "        @store = {}"
        lines << "      end"
        lines << ""
        lines << "      def find(id)"
        lines << "        @store[id]"
        lines << "      end"
        lines << ""
        lines << "      def save(#{snake})"
        lines << "        @store[#{snake}.id] = #{snake}"
        lines << "      end"
        lines << ""
        lines << "      def delete(id)"
        lines << "        @store.delete(id)"
        lines << "      end"
        lines << ""
        lines << "      def all"
        lines << "        @store.values"
        lines << "      end"
        lines << ""
        lines << "      def count"
        lines << "        @store.size"
        lines << "      end"
        lines << ""
        lines.concat(query_lines(6))
        lines << ""
        lines << "      def clear"
        lines << "        @store.clear"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Generates the lines of the +query+ method body for the memory adapter.
      #
      # @param indent [Integer] number of leading spaces for indentation
      # @return [Array<String>] the lines of the +query+ method
      def operator_module
        @mixin_prefix == "Hecks" ? "Hecks::Querying::Operators" : "#{@mixin_prefix}::Runtime::Operators"
      end

      def query_lines(indent)
        pad = " " * indent
        [
          "#{pad}def query(conditions: {}, order_key: nil, order_direction: :asc, limit: nil, offset: nil)",
          "#{pad}  results = @store.values",
          "#{pad}  unless conditions.empty?",
          "#{pad}    results = results.select do |obj|",
          "#{pad}      conditions.all? do |k, v|",
          "#{pad}        next false unless obj.respond_to?(k)",
          "#{pad}        actual = obj.send(k)",
          "#{pad}        v.is_a?(#{operator_module}::Operator) ? v.match?(actual) : actual == v",
          "#{pad}      end",
          "#{pad}    end",
          "#{pad}  end",
          "#{pad}  if order_key",
          "#{pad}    results = results.sort_by { |obj| val = obj.respond_to?(order_key) ? obj.send(order_key) : nil; val.nil? ? \"\" : val }",
          "#{pad}    results = results.reverse if order_direction == :desc",
          "#{pad}  end",
          "#{pad}  results = results.drop([offset, 0].max) if offset",
          "#{pad}  results = results.take([limit, 0].max) if limit",
          "#{pad}  results",
          "#{pad}end"
        ]
      end
    end
    end
  end
end
