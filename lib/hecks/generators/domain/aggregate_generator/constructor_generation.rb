module Hecks
  module Generators
    module Domain
      class AggregateGenerator < Hecks::Generator
        # Hecks::Generators::Domain::AggregateGenerator::ConstructorGeneration
        #
        # Mixin that generates an initialize method for aggregates with keyword
        # arguments, identity assignment, and default handling. Currently unused --
        # Hecks::Model provides identity, timestamps, and equality at runtime.
        # Retained for potential future use when aggregates need explicit constructors.
        #
        # When +@has_keyword_attrs+ is true (i.e., an attribute name collides with a
        # Ruby keyword), generates a +**kwargs+ constructor. Otherwise, generates
        # named keyword parameters with defaults.
        #
        # == Usage
        #
        #   class AggregateGenerator
        #     include ConstructorGeneration
        #   end
        #
        module ConstructorGeneration
          private

          # Generates the +initialize+ method lines for an aggregate class.
          #
          # Handles two forms:
          # - +**kwargs+ form when any attribute name is a Ruby keyword
          # - Named keyword parameters form otherwise, with multi-line formatting
          #   when there are more than 2 parameters
          #
          # The generated constructor assigns +@id+ (defaulting to +generate_id+),
          # sets each attribute (freezing list attributes), and calls +validate!+
          # and +check_invariants!+.
          #
          # @return [Array<String>] lines of Ruby source code for the initialize method
          def constructor_lines
            lines = []
            if @has_keyword_attrs
              lines << "    def initialize(**kwargs)"
              lines << "      @id = kwargs[:id] || generate_id"
              @user_attrs.each do |attr|
                if attr.list?
                  lines << "      @#{attr.name} = (kwargs[:#{attr.name}] || []).freeze"
                elsif attr.default
                  lines << "      @#{attr.name} = kwargs.fetch(:#{attr.name}, #{attr.default.inspect})"
                else
                  lines << "      @#{attr.name} = kwargs[:#{attr.name}]"
                end
              end
            else
              params = constructor_params
              if params.size <= 2
                lines << "    def initialize(#{params.join(", ")})"
              else
                lines << "    def initialize("
                params.each_with_index do |p, i|
                  suffix = i < params.size - 1 ? "," : ""
                  lines << "      #{p}#{suffix}"
                end
                lines << "    )"
              end
              lines << "      @id = id || generate_id"
              @user_attrs.each do |attr|
                if attr.list?
                  lines << "      @#{attr.name} = #{attr.name}.freeze"
                else
                  lines << "      @#{attr.name} = #{attr.name}"
                end
              end
            end
            lines << "      validate!"
            lines << "      check_invariants!"
            lines << "    end"
            lines
          end

          # Builds the list of keyword parameter strings for the constructor signature.
          #
          # Each user attribute becomes a keyword parameter with a default:
          # - List attributes default to +[]+
          # - Attributes with explicit defaults use those values
          # - Other attributes default to +nil+
          # An +id: nil+ parameter is always appended.
          #
          # @return [Array<String>] parameter strings (e.g., ["name: nil", "toppings: []", "id: nil"])
          def constructor_params
            params = @user_attrs.map do |attr|
              if attr.list?
                "#{attr.name}: []"
              elsif attr.default
                "#{attr.name}: #{attr.default.inspect}"
              else
                "#{attr.name}: nil"
              end
            end
            params << "id: nil"
            params
          end
        end
      end
    end
  end
end
