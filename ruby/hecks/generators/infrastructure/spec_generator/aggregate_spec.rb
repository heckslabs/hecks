module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        # Hecks::Generators::Infrastructure::SpecGenerator::AggregateSpec
        #
        # Generates behavioral RSpec specs for aggregate classes: construction,
        # validations, invariants, and identity. Mixed into SpecGenerator.
        #
        module AggregateSpec
          include HecksTemplating::NamingHelpers
          # Generates a complete RSpec spec file for an aggregate class.
          #
          # The generated spec covers:
          # - Construction: verifies ID assignment and each attribute's value
          # - Validations: tests presence rules by passing +nil+ for required fields
          # - Invariants: generates TODO placeholders for each invariant rule
          # - Identity: verifies equality by ID (same ID = equal, different ID = not equal)
          #
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
          #   to generate specs for
          # @return [String] the complete RSpec file content
          def generate_aggregate_spec(aggregate)
            safe_name = bluebook_constant_name(aggregate.name)
            fqn = full_class_name(safe_name)
            snake = bluebook_snake_name(safe_name)
            lines = []

            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe #{fqn} do"

            lines.concat(construction_spec(aggregate, safe_name, snake))
            lines.concat(validation_specs(aggregate))
            lines.concat(invariant_specs(aggregate))
            lines.concat(identity_spec(aggregate, safe_name))

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          # Generates the "creating a <Name>" describe block with subject and
          # per-attribute expectations.
          #
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
          # @param safe_name [String] PascalCase sanitized aggregate name
          # @param snake [String] snake_case aggregate name for the subject variable
          # @return [Array<String>] lines of the construction spec block
          def construction_spec(aggregate, safe_name, snake)
            lines = []
            lines << "  describe \"creating a #{safe_name}\" do"
            lines << "    subject(:#{snake}) { described_class.new(#{example_args(aggregate)}) }"
            lines << ""
            lines << "    it \"assigns an id\" do"
            lines << "      expect(#{snake}.id).not_to be_nil"
            lines << "    end"
            aggregate.attributes.each do |attr|
              next if Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(attr.name.to_s)
              lines << ""
              if %w[Date DateTime].include?(attr.type.to_s)
                lines << "    it \"sets #{attr.name}\" do"
                lines << "      expect(#{snake}.#{attr.name}).not_to be_nil"
                lines << "    end"
              else
                lines << "    it \"sets #{attr.name}\" do"
                lines << "      expect(#{snake}.#{attr.name}).to eq(#{example_value(attr)})"
                lines << "    end"
              end
            end
            lines << "  end"
            lines
          end

          # Generates validation spec blocks for each validation rule on the aggregate.
          # Currently handles +:presence+ (rejects nil) and +:uniqueness+ (placeholder).
          #
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
          # @return [Array<String>] lines of validation spec blocks
          def validation_specs(aggregate)
            lines = []
            aggregate.validations.each do |v|
              lines << ""
              lines << "  describe \"#{v.field} validation\" do"
              if v.rules[:presence]
                lines << "    it \"rejects nil #{v.field}\" do"
                lines << "      expect {"
                lines << "        described_class.new(#{example_args_without(aggregate, v.field)})"
                lines << "      }.to raise_error(#{mod_name}::ValidationError, /#{v.field}/)"
                lines << "    end"
              end
              if v.rules[:uniqueness]
                lines << "    it \"enforces unique #{v.field}\" do"
                lines << "      # Uniqueness is enforced at the persistence layer"
                lines << "    end"
              end
              lines << "  end"
            end
            lines
          end

          # Generates TODO-style invariant spec blocks for each invariant rule.
          #
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
          # @return [Array<String>] lines of invariant spec blocks (with TODO comments)
          def invariant_specs(aggregate)
            lines = []
            aggregate.invariants.each do |inv|
              lines << ""
              lines << "  describe \"invariant: #{inv.message}\" do"
              lines << "    it \"raises InvariantError when violated\" do"
              lines << "      # TODO: construct an instance that violates: #{inv.message}"
              lines << "      # expect { described_class.new(...) }.to raise_error(#{mod_name}::InvariantError)"
              lines << "    end"
              lines << "  end"
            end
            lines
          end

          # Generates the identity equality spec block, testing that two aggregates
          # with the same ID are equal and two with different IDs are not.
          #
          # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
          # @param safe_name [String] PascalCase sanitized aggregate name
          # @return [Array<String>] lines of the identity spec block
          def identity_spec(aggregate, safe_name)
            lines = []
            lines << ""
            lines << "  describe \"identity\" do"
            lines << "    it \"two #{safe_name}s with the same id are equal\" do"
            lines << "      id = SecureRandom.uuid"
            lines << "      a = described_class.new(#{example_args_with(aggregate, id: "id")})"
            lines << "      b = described_class.new(#{example_args_with(aggregate, id: "id")})"
            lines << "      expect(a).to eq(b)"
            lines << "    end"
            lines << ""
            lines << "    it \"two #{safe_name}s with different ids are not equal\" do"
            lines << "      a = described_class.new(#{example_args(aggregate)})"
            lines << "      b = described_class.new(#{example_args(aggregate)})"
            lines << "      expect(a).not_to eq(b)"
            lines << "    end"
            lines << "  end"
            lines
          end
        end
      end
    end
  end
end
