module Hecks
  class Workshop
    class WebRunner
      class StateSerializer
        # Hecks::Workshop::WebRunner::StateSerializer::AggregateSerializer
        #
        # Serializes aggregate builders into JSON-ready hashes including
        # attributes, commands, events, value objects, entities, policies,
        # queries, specifications, references, lifecycle, and subscribers.
        #
        #   AggregateSerializer.new(workshop, domain_groups: {}, domains: []).call
        #   # => [{ name: "Pizza", attributes: [...], commands: [...], ... }]
        #
        class AggregateSerializer
          def initialize(workshop, domain_groups:, domains:)
            @workshop = workshop
            @domain_groups = domain_groups
            @domains = domains
          end

          def call
            @workshop.aggregate_builders.values.map do |builder|
              serialize_one(builder.build)
            end
          end

          private

          def serialize_one(agg)
            {
              name:           agg.name,
              domain:         @domain_groups[agg.name],
              attributes:     serialize_attrs(agg),
              commands:       serialize_commands(agg),
              events:         agg.events.map(&:name),
              value_objects:  serialize_nested(agg.value_objects),
              entities:       serialize_nested(agg.entities),
              policies:       serialize_policies(agg),
              queries:        agg.queries.map(&:name),
              specifications: agg.specifications.map(&:name),
              references_to:  serialize_references(agg),
              lifecycle:      serialize_lifecycle(agg),
              subscribers:    serialize_subscribers(agg)
            }
          end

          def serialize_attrs(agg)
            refs = agg.references || []
            attrs = agg.attributes.map { |attr| format_attr(attr) }
            refs.each do |ref|
              attrs << { name: ref.name, type: "reference_to(#{ref.type})" }
            end
            attrs
          end

          def serialize_commands(agg)
            agg.commands.map do |cmd|
              cmd_attrs = cmd.attributes.map { |attr| { name: attr.name, type: attr.type.to_s } }
              { name: cmd.name, attributes: cmd_attrs }
            end
          end

          def serialize_nested(collection)
            collection.map do |item|
              { name: item.name, attributes: item.attributes.map { |attr| format_attr(attr) } }
            end
          end

          def serialize_policies(agg)
            agg.policies.map do |policy|
              { name: policy.name, event: policy.event_name, trigger: policy.trigger_command }
            end
          end

          def serialize_references(agg)
            (agg.references || []).map do |ref|
              { name: ref[:name], type: ref[:type], kind: ref[:kind]&.to_s, domain: ref[:domain] }
            end
          end

          def format_attr(attr)
            type_str = attr.list? ? "list_of(#{attr.type})" : attr.type.to_s
            { name: attr.name, type: type_str }
          end

          def serialize_lifecycle(agg)
            orig = find_original_aggregate(agg.name)
            lc = orig&.lifecycle
            return nil unless lc

            transitions = lc.transitions.map do |cmd, transition|
              { command: cmd, target: transition.target, from: transition.from }
            end
            { field: lc.field.to_s, default: lc.default, states: lc.states, transitions: transitions }
          end

          def serialize_subscribers(agg)
            orig = find_original_aggregate(agg.name)
            return [] unless orig

            orig.subscribers.map do |sub|
              { name: sub.name, event: sub.event_name, async: sub.async }
            end
          end

          def find_original_aggregate(name)
            @domains.each do |domain|
              found = domain.aggregates.find { |agg| agg.name == name }
              return found if found
            end
            nil
          end
        end
      end
    end
  end
end
