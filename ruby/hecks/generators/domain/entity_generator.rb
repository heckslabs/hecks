module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::EntityGenerator
    #
    # Generates mutable sub-entity classes that include Hecks::Model. Entities
    # have UUID identity, identity-based equality, and are NOT frozen -- unlike
    # value objects. Supports invariant checks and list attributes.
    # Part of Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # Entities are nested inside their parent aggregate class (e.g.,
    # +BankingDomain::Account::LedgerEntry+). They get their own +attribute+
    # declarations and optional +check_invariants!+ method.
    #
    # == Usage
    #
    #   gen = EntityGenerator.new(entity, domain_module: "BankingDomain", aggregate_name: "Account")
    #   gen.generate  # => "module BankingDomain\n  class Account\n    class LedgerEntry\n  ..."
    #
    class EntityGenerator

      # Initializes the entity generator.
      #
      # @param entity [Object] the entity model object; provides +name+, +attributes+,
      #   and +invariants+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(entity, domain_module:, aggregate_name:)
        @entity = entity
        @domain_module = domain_module
        @aggregate_name = aggregate_name
      end

      # Generates the full Ruby source code for the entity class.
      #
      # Produces a class nested under the aggregate that includes Hecks::Model,
      # declares attributes, and optionally defines a +check_invariants!+ method.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "require 'hecks/mixins/model'"
        lines << ""
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    class #{@entity.name}"
        lines << "      include Hecks::Model"
        lines << ""
        @entity.attributes.each do |attr|
          lines << "      attribute #{attribute_declaration(attr)}"
        end
        unless @entity.invariants.empty?
          lines << ""
          lines << "      private"
          lines << ""
          lines.concat(invariant_lines)
        end
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Formats a single attribute declaration for the Hecks::Model DSL.
      #
      # List attributes get +default: []+ and +freeze: true+. Attributes with
      # explicit defaults get +default: <value>+. Plain attributes get just the name.
      #
      # @param attr [Hecks::BluebookModel::Structure::Attribute] the attribute to declare
      # @return [String] the formatted declaration (e.g., ":amount" or ":entries, default: [], freeze: true")
      def attribute_declaration(attr)
        parts = [":#{attr.name}"]
        if attr.list?
          parts << "default: []"
          parts << "freeze: true"
        elsif attr.default
          parts << "default: #{attr.default.inspect}"
        end
        parts.join(", ")
      end

      # Generates lines for the +check_invariants!+ method.
      #
      # Each invariant produces a line that evaluates its block via +instance_eval+
      # and raises +InvariantError+ (scoped to the domain module) if the block
      # returns falsy.
      #
      # @return [Array<String>] lines of Ruby source code for the check_invariants! method
      def invariant_lines
        if @entity.invariants.empty?
          return ["      def check_invariants!; end"]
        end

        lines = []
        lines << "      def check_invariants!"
        @entity.invariants.each do |inv|
          lines << "        raise #{@domain_module}::InvariantError, #{inv.message.inspect} unless instance_eval(&#{source_from_block(inv.block)})"
        end
        lines << "      end"
        lines
      end

      # Converts a block into a proc source string.
      #
      # @param block [Proc] the invariant's condition block
      # @return [String] a proc literal string (e.g., 'proc { amount > 0 }')
      def source_from_block(block)
        "proc { #{Hecks::Utils.block_source(block)} }"
      end
    end
    end
  end
end
