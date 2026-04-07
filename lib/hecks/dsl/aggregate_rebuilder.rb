# Hecks::DSL::AggregateRebuilder
#
# Reconstructs an AggregateBuilder from a built Aggregate model object.
# Used when loading an existing domain.rb and needing to work with builder
# objects (e.g., in the interactive console session or DslSerializer round-trips).
# Restores attributes, references, value objects, commands, validations,
# scopes, and reactive policies.
#
#   builder = DSL::AggregateRebuilder.from_aggregate(aggregate)
#   builder.build  # => a new Aggregate equivalent to the original
#
module Hecks
  module DSL
    class AggregateRebuilder
      # Reconstruct an AggregateBuilder from a built Aggregate IR object.
      #
      # @param aggregate [DomainModel::Structure::Aggregate] the aggregate IR to reconstruct from
      # @return [AggregateBuilder] a builder pre-populated with equivalent declarations
      def self.from_aggregate(aggregate)
        builder = DSL::AggregateBuilder.new(aggregate.name)
        aggregate.attributes.each do |attr|
          type = attr.list? ? { list: attr.type } : attr.type
          builder.attribute(attr.name, type)
        end
        aggregate.references.each do |ref|
          qualified = ref.domain ? "#{ref.domain}::#{ref.type}" : ref.type
          builder.reference_to(qualified, role: ref.name.to_s)
        end
        aggregate.value_objects.each do |vo|
          builder.value_object(vo.name) do
            vo.attributes.each do |attr|
              type = attr.list? ? { list: attr.type } : attr.type
              attribute attr.name, type
            end
          end
        end
        aggregate.entities.each do |ent|
          builder.entity(ent.name) do
            ent.attributes.each do |attr|
              type = attr.list? ? { list: attr.type } : attr.type
              attribute attr.name, type
            end
          end
        end
        aggregate.commands.each do |cmd|
          builder.command(cmd.name) do
            cmd.attributes.each do |attr|
              type = attr.list? ? { list: attr.type } : attr.type
              attribute attr.name, type
            end
            cmd.references.each do |ref|
              qualified = ref.domain ? "#{ref.domain}::#{ref.type}" : ref.type
              reference_to(qualified, role: ref.name.to_s)
            end
          end
        end
        aggregate.validations.each do |v|
          builder.validation(v.field, v.rules)
        end
        aggregate.scopes.each do |s|
          builder.scope(s.name, s.conditions)
        end
        aggregate.policies.each do |pol|
          builder.policy(pol.name) do
            on pol.event_name
            trigger pol.trigger_command
          end
        end
        aggregate.specifications.each do |spec|
          builder.specification(spec.name, &spec.block)
        end
        builder
      end
    end
  end
end
