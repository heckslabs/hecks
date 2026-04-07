Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::GeneratorsParagraph,
  base_dir: File.expand_path("aggregate_generator", __dir__)
)

module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::AggregateGenerator
    #
    # Generates aggregate root classes that include Hecks::Model. Emits
    # attribute declarations via the Model DSL, plus validation and invariant
    # methods from the ValidationGeneration and InvariantGeneration mixins.
    # Identity, timestamps, and equality come from Hecks::Model at runtime.
    # Part of Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # The generated class includes:
    # - +attribute+ declarations for each user-defined attribute
    # - State predicate methods if a lifecycle is defined (e.g., +active?+, +archived?+)
    # - Enum constant arrays (e.g., +VALID_STATUS+) for attributes with enum constraints
    # - A private +validate!+ method combining presence checks, type checks, and enum checks
    # - A private +check_invariants!+ method for domain invariants
    #
    # == Usage
    #
    #   gen = AggregateGenerator.new(agg, domain_module: "PizzasDomain")
    #   gen.generate  # => "module PizzasDomain\n  class Pizza\n  ..."
    #
    class AggregateGenerator < Hecks::Generator
      include ValidationGeneration
      include InvariantGeneration

      # Initializes the generator with an aggregate model object and output context.
      #
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate to generate code for;
      #   provides +name+, +attributes+, +validations+, +invariants+, and +lifecycle+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      #   (e.g., "PizzasDomain")
      def initialize(aggregate, domain_module:, mixin_prefix: "Hecks")
        @aggregate = aggregate
        @domain_module = domain_module
        @mixin_prefix = mixin_prefix
        @safe_name = domain_constant_name(@aggregate.name)
        @user_attrs = @aggregate.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
      end

      # Generates the full Ruby source code for the aggregate root class.
      #
      # Produces a complete module-wrapped class definition including:
      # - A +require+ for the Hecks::Model mixin
      # - +attribute+ declarations for each non-reserved attribute
      # - State predicate methods from the lifecycle (if present)
      # - Enum constant definitions for constrained attributes
      # - A combined +validate!+ method (presence, type, and enum checks)
      # - A +check_invariants!+ method for domain invariants
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        if @mixin_prefix == "Hecks"
          lines << "require 'hecks/mixins/model'"
          lines << ""
        end
        lines << "module #{@domain_module}"
        lines << "  class #{@safe_name}"
        lines << "    include #{@mixin_prefix}::#{@mixin_prefix == "Hecks" ? "Model" : "Runtime::Model"}"
        if @mixin_prefix != "Hecks"
          lines << ""
          lines << "    class << self"
          lines << "      attr_accessor :repository, :event_bus, :command_bus"
          lines << "    end"
        end
        lines << ""
        @user_attrs.each do |attr|
          lines << "    attribute #{attribute_declaration(attr)}"
        end
        (@aggregate.references || []).each do |ref|
          lines << "    attribute :#{ref.name}"
        end
        unless (@aggregate.computed_attributes || []).empty?
          lines << ""
          lines << "    # Computed attributes — derived values, not stored"
          @aggregate.computed_attributes.each do |ca|
            lines << "    def #{ca.name}"
            lines << "      #{Hecks::Utils.block_source(ca.block)}"
            lines << "    end"
          end
        end
        if @aggregate.lifecycle
          lines << ""
          lines << "    # State predicates — see lifecycle.rb for full state machine"
          @aggregate.lifecycle.states.each do |state|
            lines << "    def #{state}?; #{@aggregate.lifecycle.field} == \"#{state}\"; end"
          end
        end
        enum_attrs = @user_attrs.select(&:enum)
        unless enum_attrs.empty?
          lines << ""
          enum_attrs.each do |attr|
            values = attr.enum.map(&:inspect).join(", ")
            const = "VALID_#{attr.name.to_s.upcase}"
            lines << "    #{const} = [#{values}].freeze unless defined?(#{const})"
          end
        end
        unless @aggregate.validations.empty? && @aggregate.invariants.empty? && enum_attrs.empty?
          lines << ""
          lines << "    private"
          lines << ""
          lines.concat(combined_validation_lines(enum_attrs))
          lines << "" unless (@aggregate.validations.empty? && enum_attrs.empty?) || @aggregate.invariants.empty?
          lines.concat(invariant_lines) unless @aggregate.invariants.empty?
        end
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Generates the combined +validate!+ method lines including presence checks,
      # type checks, and enum validation for constrained attributes.
      #
      # @param enum_attrs [Array<Hecks::DomainModel::Structure::Attribute>] attributes
      #   that have enum constraints defined
      # @return [Array<String>] lines of Ruby source code for the validate! method
      def combined_validation_lines(enum_attrs)
        lines = ["    def validate!"]
        @aggregate.validations.each do |v|
          field = v.field
          if v.rules[:presence]
            lines << "      raise ValidationError.new(\"#{field} can't be blank\", field: :#{field}, rule: :presence) if #{field}.nil? || (#{field}.respond_to?(:empty?) && #{field}.empty?)"
          end
          if v.rules[:type]
            lines << "      raise ValidationError.new(\"#{field} must be a #{v.rules[:type]}\", field: :#{field}, rule: :type) unless #{field}.is_a?(#{v.rules[:type]})"
          end
        end
        enum_attrs.each do |attr|
          const = "VALID_#{attr.name.to_s.upcase}"
          lines << "      if #{attr.name} && !#{const}.include?(#{attr.name})"
          lines << "        raise ValidationError, \"#{attr.name} must be one of: \#{#{const}.join(', ')}, got: \#{#{attr.name}}\""
          lines << "      end"
        end
        lines << "    end"
        lines
      end

      # Formats a single attribute declaration for the Hecks::Model DSL.
      #
      # List attributes get +default: []+ and +freeze: true+. Attributes with
      # explicit defaults get +default: <value>+. Plain attributes get just the name.
      #
      # @param attr [Hecks::DomainModel::Structure::Attribute] the attribute to declare
      # @return [String] the formatted attribute declaration (e.g., ":name" or ":toppings, default: [], freeze: true")
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
    end
    end
  end
end
