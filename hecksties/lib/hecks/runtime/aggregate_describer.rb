# Hecks::AggregateDescriber
#
# Shared formatting logic for describing an aggregate's structure.
# Used by both Runtime::Introspection and Workshop::AggregateHandle::Presenter
# to avoid duplicating the section-by-section describe output.
#
#   lines = Hecks::AggregateDescriber.describe_lines(aggregate)
#   puts lines.join("\n")
#
module Hecks
  # Hecks::AggregateDescriber
  #
  # Shared formatting logic for describing an aggregate's structure as text lines.
  #
  module AggregateDescriber
    def self.describe_lines(agg)
      lines = []
      lines << agg.name
      lines << ""

      lines.concat(attributes_section(agg))
      lines.concat(value_objects_section(agg))
      lines.concat(entities_section(agg))
      lines.concat(commands_section(agg))
      lines.concat(validations_section(agg))
      lines.concat(invariants_section(agg))
      lines.concat(policies_section(agg))
      lines.concat(queries_section(agg))
      lines.concat(scopes_section(agg))
      lines.concat(subscribers_section(agg))
      lines.concat(specifications_section(agg))
      lines
    end

    def self.attributes_section(agg)
      return [] if agg.attributes.empty?
      lines = ["  Attributes:"]
      agg.attributes.each do |attr|
        lines << "    #{attr.name}: #{Hecks::Utils.type_label(attr)}"
      end
      lines
    end

    def self.value_objects_section(agg)
      return [] if agg.value_objects.empty?
      lines = ["  Value Objects:"]
      agg.value_objects.each do |vo|
        attrs = vo.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
        lines << "    #{vo.name} (#{attrs})"
        vo.invariants.each { |inv| lines << "      invariant: #{inv.message}" }
      end
      lines
    end

    def self.entities_section(agg)
      return [] if agg.entities.empty?
      lines = ["  Entities:"]
      agg.entities.each do |ent|
        attrs = ent.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
        lines << "    #{ent.name} (#{attrs})"
        ent.invariants.each { |inv| lines << "      invariant: #{inv.message}" }
      end
      lines
    end

    def self.commands_section(agg)
      return [] if agg.commands.empty?
      lines = ["  Commands:"]
      agg.commands.each_with_index do |cmd, idx|
        event = agg.events[idx]
        attrs = cmd.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
        lines << "    #{cmd.name}(#{attrs}) -> #{event&.name}"
      end
      lines
    end

    def self.validations_section(agg)
      return [] if agg.validations.empty?
      lines = ["  Validations:"]
      agg.validations.each do |validation|
        lines << "    #{validation.field}: #{validation.rules.keys.join(', ')}"
      end
      lines
    end

    def self.invariants_section(agg)
      return [] if agg.invariants.empty?
      lines = ["  Invariants:"]
      agg.invariants.each { |inv| lines << "    #{inv.message}" }
      lines
    end

    def self.policies_section(agg)
      return [] if agg.policies.empty?
      lines = ["  Policies:"]
      agg.policies.each do |pol|
        async_label = pol.async ? " [async]" : ""
        lines << "    #{pol.name} (#{pol.event_name} -> #{pol.trigger_command})#{async_label}"
      end
      lines
    end

    def self.queries_section(agg)
      return [] if agg.queries.empty?
      lines = ["  Queries:"]
      agg.queries.each { |query| lines << "    #{query.name}" }
      lines
    end

    def self.scopes_section(agg)
      return [] if agg.scopes.empty?
      lines = ["  Scopes:"]
      agg.scopes.each { |scope| lines << "    #{scope.name}" }
      lines
    end

    def self.subscribers_section(agg)
      return [] if agg.subscribers.empty?
      lines = ["  Subscribers:"]
      agg.subscribers.each { |sub| lines << "    on #{sub.event_name}" }
      lines
    end

    def self.specifications_section(agg)
      return [] if agg.specifications.empty?
      lines = ["  Specifications:"]
      agg.specifications.each { |spec| lines << "    #{spec.name}" }
      lines
    end
  end
end
