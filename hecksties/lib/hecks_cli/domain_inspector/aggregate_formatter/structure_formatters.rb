# Hecks::CLI::DomainInspector::AggregateFormatter::StructureFormatters
#
# Formats the structural elements of an aggregate: attributes, value objects,
# and entities. Mixed into AggregateFormatter to keep concerns separated.
#
#   include StructureFormatters
#
module Hecks
  class CLI
    class DomainInspector
      class AggregateFormatter
        module StructureFormatters
          private

          def format_attributes
            return [] if @agg.attributes.empty?
            lines = ["  Attributes:"]
            @agg.attributes.each do |attr|
              lines << "    #{attr.name}: #{Hecks::Utils.type_label(attr)}"
            end
            lines << ""
          end

          def format_value_objects
            return [] if @agg.value_objects.empty?
            lines = ["  Value Objects:"]
            @agg.value_objects.each do |vo|
              attrs = vo.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
              lines << "    #{vo.name} (#{attrs})"
              vo.invariants.each { |inv| lines << "      invariant: #{inv.message}" }
            end
            lines << ""
          end

          def format_entities
            return [] if @agg.entities.empty?
            lines = ["  Entities:"]
            @agg.entities.each do |ent|
              attrs = ent.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
              lines << "    #{ent.name} (#{attrs})"
              ent.invariants.each { |inv| lines << "      invariant: #{inv.message}" }
            end
            lines << ""
          end
        end
      end
    end
  end
end
