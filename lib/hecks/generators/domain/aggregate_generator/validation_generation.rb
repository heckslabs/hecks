module Hecks
  module Generators
    module Domain
      class AggregateGenerator < Hecks::Generator
        # Hecks::Generators::Domain::AggregateGenerator::ValidationGeneration
        #
        # Mixin that generates the +validate!+ method for aggregate classes.
        # Produces presence and type checks based on the aggregate's validation
        # rules defined in the DSL. If no validations are defined, generates a
        # no-op method. Part of Generators::Domain, mixed into AggregateGenerator.
        #
        # Note: In current usage, AggregateGenerator calls +combined_validation_lines+
        # (defined on itself) which also handles enum checks. This module's
        # +validation_lines+ method is the standalone variant without enum support.
        #
        # == Usage
        #
        #   class AggregateGenerator
        #     include ValidationGeneration
        #   end
        #
        module ValidationGeneration
          private

          # Generates lines for the +validate!+ method based on the aggregate's
          # validation rules.
          #
          # Supports two rule types:
          # - +:presence+ -- raises +ValidationError+ if the field is nil or empty
          # - +:type+ -- raises +ValidationError+ if the field is not an instance of
          #   the specified class
          #
          # When no validations are defined, returns a single-line no-op method.
          #
          # @return [Array<String>] lines of Ruby source code for the validate! method
          def validation_lines
            if @aggregate.validations.empty?
              return ["    def validate!; end"]
            end

            lines = ["    def validate!"]
            @aggregate.validations.each do |v|
              field = v.field
              rules = v.rules

              if rules[:presence]
                lines << "      raise ValidationError, \"#{field} can't be blank\" if #{field}.nil? || (#{field}.respond_to?(:empty?) && #{field}.empty?)"
              end

              if rules[:type]
                lines << "      raise ValidationError, \"#{field} must be a #{rules[:type]}\" unless #{field}.is_a?(#{rules[:type]})"
              end
            end
            lines << "    end"
            lines
          end
        end
      end
    end
  end
end
