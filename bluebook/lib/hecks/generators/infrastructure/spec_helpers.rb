
module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::SpecHelpers
    #
    # Private helper methods for SpecGenerator: example argument generation,
    # example values by type, and spec snippet builders for attributes,
    # validations, invariants, and equality. Part of Generators::Infrastructure,
    # mixed into SpecGenerator.
    #
    #   # Mixed into SpecGenerator:
    #   example_args(aggregate)  # => "name: \"example\", size: \"example\""
    #
    module SpecHelpers
      include HecksTemplating::NamingHelpers
      private

      # Returns the fully qualified class name for use in RSpec +describe+ blocks.
      #
      # @param class_path [String] the relative class path within the domain module
      #   (e.g. +"Pizza::Commands::CreatePizza"+)
      # @return [String] the fully qualified name (e.g. +"PizzasDomain::Pizza::Commands::CreatePizza"+)
      def full_class_name(class_path)
        mod = bluebook_module_name(@domain.name)
        "#{mod}::#{class_path}"
      end

      # Builds a keyword argument string from all attributes of a domain object,
      # using +example_value+ for each. Formats inline for 1-2 args, multi-line
      # for 3+.
      #
      # @param thing [#attributes] any domain IR object with an +attributes+ method
      #   (aggregate, command, event, value object, entity)
      # @return [String] the formatted keyword arguments
      #   (e.g. +"name: \"example\", size: 1"+)
      def example_args(thing)
        parts = thing.attributes.map do |attr|
          "#{attr.name}: #{example_value(attr)}"
        end
        if parts.size <= 2
          parts.join(", ")
        else
          "\n          " + parts.join(",\n          ") + "\n        "
        end
      end

      # Returns a representative Ruby literal string for an attribute, suitable
      # for embedding in generated spec source code.
      #
      # Type mapping:
      # - List attributes -> +"[]"+
      # - Reference attributes -> +"\"ref-id-123\""+
      # - Enum attributes -> the first enum value (inspected)
      # - +String+ -> +"\"example\""+
      # - +Integer+ -> +"1"+
      # - +Float+ -> +"1.0"+
      # - +Boolean+/+TrueClass+/+FalseClass+ -> +"true"+
      # - +Date+ -> +"Date.today"+
      # - +DateTime+ -> +"DateTime.now"+
      # - All others -> +"\"example\""+
      #
      # @param attr [Hecks::BluebookModel::Structure::Attribute] the attribute IR
      # @return [String] a Ruby literal suitable for source code embedding
      def example_value(attr)
        return "[]" if attr.list?
        return attr.enum.first.inspect if attr.enum&.any?

        case attr.type.to_s
        when "String"  then "\"example\""
        when "Integer" then "1"
        when "Float"   then "1.0"
        when "Boolean", "TrueClass", "FalseClass" then "true"
        when "Date"    then "Date.today"
        when "DateTime" then "DateTime.now"
        else "\"example\""
        end
      end

      # Generates simple "has <attr>" spec lines for each attribute on an aggregate.
      # Used by the legacy spec generation path.
      #
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      # @return [String] joined spec lines
      def attribute_specs(aggregate)
        safe_name = bluebook_constant_name(aggregate.name)
        snake = bluebook_snake_name(safe_name)
        aggregate.attributes.map do |attr|
          "    it \"has #{attr.name}\" do\n      expect(#{snake}.#{attr.name}).not_to be_nil\n    end"
        end.join("\n\n")
      end

      # Generates validation spec blocks for presence rules. Returns an empty
      # string if the aggregate has no validations.
      #
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      # @return [String] the validation spec source, or empty string
      def validation_specs(aggregate)
        return "" if aggregate.validations.empty?

        specs = aggregate.validations.map do |v|
          field = v.field
          rules = v.rules

          if rules[:presence]
            <<~RUBY.chomp
                describe "validations" do
                  it "requires #{field}" do
                    expect {
                      described_class.new(#{example_args_without(aggregate, field)})
                    }.to raise_error(#{@domain.module_name}Domain::ValidationError)
                  end
                end
            RUBY
          end
        end.compact

        specs.join("\n\n")
      end

      # Generates a placeholder invariant spec block. Returns an empty string
      # if the object has no invariants.
      #
      # @param vo [#invariants] any domain IR object with invariants
      # @return [String] the invariant spec source, or empty string
      def invariant_specs(vo)
        return "" if vo.invariants.empty?

        "  describe \"invariants\" do\n    it \"enforces invariants\" do\n      # TODO: Add specific invariant test cases\n    end\n  end"
      end

      # Generates an identity-based equality spec block for an aggregate.
      #
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      # @return [String] the equality spec source
      def equality_spec(aggregate)
        <<~RUBY.chomp
            describe "equality" do
              it "is equal to another #{aggregate.name} with the same id" do
                id = SecureRandom.uuid
                a = described_class.new(#{example_args(aggregate)}, id: id)
                b = described_class.new(#{example_args(aggregate)}, id: id)
                expect(a).to eq(b)
              end
            end
        RUBY
      end

      # Like +example_args+ but appends additional keyword arguments from +extra+.
      # Used to inject a specific +id:+ value for identity specs.
      #
      # @param thing [#attributes] any domain IR object with an +attributes+ method
      # @param extra [Hash] additional keyword arguments to append
      #   (e.g. +id: "id"+)
      # @return [String] the formatted keyword arguments
      def example_args_with(thing, **extra)
        parts = thing.attributes.map do |attr|
          "#{attr.name}: #{example_value(attr)}"
        end
        extra.each { |k, v| parts << "#{k}: #{v}" }
        if parts.size <= 2
          parts.join(", ")
        else
          "\n          " + parts.join(",\n          ") + "\n        "
        end
      end

      # Like +example_args+ but replaces the value of +excluded_field+ with +nil+.
      # Used to test presence validations by passing nil for a required field.
      #
      # @param thing [#attributes] any domain IR object with an +attributes+ method
      # @param excluded_field [String, Symbol] the attribute name to set to +nil+
      # @return [String] the formatted keyword arguments with one field set to nil
      def example_args_without(thing, excluded_field)
        parts = thing.attributes.map do |attr|
          if attr.name == excluded_field
            "#{attr.name}: nil"
          else
            "#{attr.name}: #{example_value(attr)}"
          end
        end
        if parts.size <= 2
          parts.join(", ")
        else
          "\n          " + parts.join(",\n          ") + "\n        "
        end
      end
    end
    end
  end
end
