module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::ValueObjectGenerator
    #
    # Generates frozen, immutable value object classes with value-based
    # equality (+==+, +eql?+, +hash+). Value objects are nested inside their
    # parent aggregate class (e.g., +PizzasDomain::Pizza::Topping+).
    #
    # Supports:
    # - Invariant checks via +check_invariants!+ called before freeze
    # - List attributes that are frozen on creation
    # - Ruby keyword-safe attribute names via +**kwargs+ constructor form
    # - Value-based equality comparing all attributes
    # - Proper +hash+ implementation for use in Sets and as Hash keys
    #
    # When any attribute name is a Ruby keyword (e.g., +class+, +end+), the
    # generator switches to +**kwargs+ form and uses +send+ for attribute
    # access in equality/hash methods to avoid syntax errors.
    #
    # Part of Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # == Usage
    #
    #   gen = ValueObjectGenerator.new(vo, domain_module: "PizzasDomain", aggregate_name: "Pizza")
    #   gen.generate  # => "module PizzasDomain\n  class Pizza\n    class Topping\n  ..."
    #
    class ValueObjectGenerator

      # Initializes the value object generator.
      #
      # @param value_object [Object] the value object model; provides +name+, +attributes+,
      #   and +invariants+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(value_object, domain_module:, aggregate_name:)
        @vo = value_object
        @domain_module = domain_module
        @aggregate_name = aggregate_name
        @has_keyword_attrs = @vo.attributes.any? { |a| Hecks::Utils.ruby_keyword?(a.name) }
      end

      # Generates the full Ruby source code for the value object class.
      #
      # Produces a frozen, immutable class with:
      # - +attr_reader+ for all attributes
      # - A constructor that assigns attributes, checks invariants, and freezes
      # - Value-based +==+ and +eql?+ methods comparing all attributes
      # - A +hash+ method combining class and all attribute values
      # - A private +check_invariants!+ method (no-op if no invariants defined)
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    class #{@vo.name}"
        lines << "      attr_reader #{@vo.attributes.map { |a| ":#{a.name}" }.join(", ")}"
        lines << ""
        if @has_keyword_attrs
          lines << "      def initialize(**kwargs)"
          @vo.attributes.each do |attr|
            if attr.list?
              lines << "        @#{attr.name} = (kwargs[:#{attr.name}] || []).freeze"
            else
              lines << "        @#{attr.name} = kwargs[:#{attr.name}]"
            end
          end
        else
          lines << "      def initialize(#{constructor_params})"
          @vo.attributes.each do |attr|
            if attr.list?
              lines << "        @#{attr.name} = #{attr.name}.freeze"
            else
              lines << "        @#{attr.name} = #{attr.name}"
            end
          end
        end
        lines << "        check_invariants!"
        lines << "        freeze"
        lines << "      end"
        lines << ""
        lines << "      def ==(other)"
        if @has_keyword_attrs
          lines << "        other.is_a?(Object.instance_method(:class).bind_call(self)) &&"
          @vo.attributes.each_with_index do |attr, i|
            suffix = i < @vo.attributes.size - 1 ? " &&" : ""
            lines << "          send(:#{attr.name}) == other.send(:#{attr.name})#{suffix}"
          end
        else
          lines << "        other.is_a?(self.class) &&"
          @vo.attributes.each_with_index do |attr, i|
            suffix = i < @vo.attributes.size - 1 ? " &&" : ""
            lines << "          #{attr.name} == other.#{attr.name}#{suffix}"
          end
        end
        lines << "      end"
        lines << "      alias eql? =="
        lines << ""
        lines << "      def hash"
        if @has_keyword_attrs
          lines << "        [Object.instance_method(:class).bind_call(self), #{@vo.attributes.map { |a| "send(:#{a.name})" }.join(", ")}].hash"
        else
          lines << "        [self.class, #{@vo.attributes.map(&:name).join(", ")}].hash"
        end
        lines << "      end"
        lines << ""
        lines << "      private"
        lines << ""
        lines.concat(invariant_lines)
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Builds the constructor parameter string for named keyword parameters.
      #
      # List attributes default to +[]+. All other attributes use required keyword
      # syntax (no default).
      #
      # @return [String] comma-separated keyword parameters (e.g., "name:, toppings: []")
      def constructor_params
        @vo.attributes.map do |attr|
          attr.list? ? "#{attr.name}: []" : "#{attr.name}:"
        end.join(", ")
      end

      # Generates lines for the +check_invariants!+ method.
      #
      # When invariants are present, each produces a line that evaluates its block
      # via +instance_eval+ and raises +InvariantError+ if falsy.
      # When no invariants are defined, returns a single-line no-op method.
      #
      # @return [Array<String>] lines of Ruby source code for the check_invariants! method
      def invariant_lines
        if @vo.invariants.empty?
          return ["      def check_invariants!; end"]
        end

        lines = []
        lines << "      def check_invariants!"
        @vo.invariants.each do |inv|
          lines << "        raise InvariantError, #{inv.message.inspect} unless instance_eval(&#{source_from_block(inv.block)})"
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
