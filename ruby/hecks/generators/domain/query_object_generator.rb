module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::QueryObjectGenerator
    #
    # Generates query modules (e.g. PizzaQueries) under Domain::Queries.
    # Each scalar, non-reference attribute gets a +by_<attribute>+ method that
    # delegates to +where()+. These modules are mixed into repositories to
    # provide typed finder methods for querying aggregates by attribute values.
    #
    # Only scalar attributes are included -- list attributes and reference
    # attributes are excluded since they cannot be directly queried with +where+.
    #
    # Part of Generators::Domain, consumed by DomainGemGenerator.
    #
    # == Usage
    #
    #   gen = QueryObjectGenerator.new(agg, domain_module: "PizzasDomain")
    #   gen.generate  # => "module PizzasDomain\n  module Queries\n    module PizzaQueries\n  ..."
    #
    class QueryObjectGenerator < Hecks::Generator

      # Initializes the query object generator.
      #
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate whose
      #   attributes will be used to generate finder methods
      # @param domain_module [String] the Ruby module name to wrap the generated module in
      def initialize(aggregate, domain_module:)
        @aggregate = aggregate
        @domain_module = domain_module
      end

      # Generates the full Ruby source code for the query module.
      #
      # Produces a module under +Domain::Queries+ named +<Aggregate>Queries+ with
      # +by_<attr>+ methods for each queryable attribute.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  module Queries"
        lines.concat(query_module_lines(4))
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Generates the inner module lines with +by_<attr>+ finder methods.
      #
      # Each queryable attribute produces a method like:
      #   def by_name(value)
      #     where(name: value)
      #   end
      #
      # @param indent [Integer] the number of spaces to indent the module body
      # @return [Array<String>] lines of Ruby source code for the query module
      def query_module_lines(indent)
        pad = " " * indent
        lines = []
        lines << "#{pad}module #{bluebook_constant_name(@aggregate.name)}Queries"
        queryable_attributes.each do |attr|
          name = attr.name
          lines << "#{pad}  def by_#{name}(value)"
          lines << "#{pad}    where(#{name}: value)"
          lines << "#{pad}  end"
          lines << ""
        end
        # Remove trailing blank line
        lines.pop if lines.last == ""
        lines << "#{pad}end"
        lines
      end

      # Filters aggregate attributes to only those that are queryable.
      #
      # Excludes list attributes (which contain collections) and reference
      # attributes (which point to other aggregates) since neither can be
      # directly matched with +where+.
      #
      # @return [Array<Hecks::BluebookModel::Structure::Attribute>] scalar, non-reference attributes
      def queryable_attributes
        @aggregate.attributes.reject(&:list?)
      end
    end
    end
  end
end
