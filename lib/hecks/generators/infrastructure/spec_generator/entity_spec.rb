module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        # Hecks::Generators::Infrastructure::SpecGenerator::EntitySpec
        #
        # Generates RSpec specs for sub-entities: identity, mutability,
        # and invariant enforcement. Mixed into SpecGenerator.
        #
        module EntitySpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec file for a sub-entity class.
          #
          # The generated spec covers:
          # - UUID identity: verifies the entity has a UUID-formatted +id+
          # - Mutability: verifies the entity is not frozen (entities are mutable,
          #   unlike value objects)
          # - Identity-based equality: two entities with the same ID are equal
          # - Invariants: generates TODO placeholders for each invariant rule
          #
          # @param entity [Hecks::DomainModel::Structure::Entity] the entity IR
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the owning
          #   aggregate, used to build the fully qualified class name
          # @return [String] the complete RSpec file content
          def generate_entity_spec(entity, aggregate)
            safe_agg = domain_constant_name(aggregate.name)
            fqn = full_class_name("#{safe_agg}::#{entity.name}")
            snake = domain_snake_name(entity.name)
            lines = []

            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe #{fqn} do"
            lines << "  subject(:#{snake}) { described_class.new(#{example_args(entity)}) }"
            lines << ""
            lines << "  it \"has a UUID id\" do"
            lines << "    expect(#{snake}.id).to match(/\\A[0-9a-f-]{36}\\z/)"
            lines << "  end"
            lines << ""
            lines << "  it \"is mutable (not frozen)\" do"
            lines << "    expect(#{snake}).not_to be_frozen"
            lines << "  end"
            lines << ""
            lines << "  it \"uses identity-based equality\" do"
            lines << "    id = SecureRandom.uuid"
            lines << "    a = described_class.new(#{example_args(entity)}, id: id)"
            lines << "    b = described_class.new(#{example_args(entity)}, id: id)"
            lines << "    expect(a).to eq(b)"
            lines << "  end"

            entity.invariants.each do |inv|
              lines << ""
              lines << "  it \"enforces: #{inv.message}\" do"
              lines << "    # TODO: construct a #{entity.name} that violates: #{inv.message}"
              lines << "    # expect { described_class.new(...) }.to raise_error(#{mod_name}::InvariantError)"
              lines << "  end"
            end

            lines << "end"
            lines.join("\n") + "\n"
          end
        end
      end
    end
  end
end
