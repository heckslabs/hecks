# Hecks::CLI::DocumentationServer::DomainSerializer
#
# Walks a domain IR and produces a JSON-ready hash for the browser.
# Reads render_mode, color, icon from Hecks::DomainPresentation —
# the compiled form of nursery/hecks/domain_presentation.bluebook.
#
#   DomainSerializer.new(domain).call
#   # => { name: "Pizzas", aggregates: [...], policies: [...] }
#
require "hecks/domain_presentation"

module Hecks
  class CLI
    class DocumentationServer
      class DomainSerializer
        def initialize(domain)
          @domain = domain
        end

        def call
          {
            name: @domain.name,
            expressions: Hecks::DomainPresentation.all,
            aggregates: @domain.aggregates.map { |a| serialize_aggregate(a) },
            policies: @domain.policies.map { |p| serialize_policy(p) }
          }
        end

        private

        def serialize_aggregate(agg)
          {
            name: agg.name,
            description: agg.description.to_s,
            sections: Hecks::DomainPresentation.express(agg),
            attributes: serialize_attributes(agg),
            commands: serialize_commands(agg),
            events: serialize_events(agg),
            value_objects: serialize_value_objects(agg),
            references: serialize_references(agg),
            lifecycle: serialize_lifecycle(agg),
            fixtures: serialize_fixtures(agg)
          }
        end

        def serialize_attributes(agg)
          agg.attributes.map do |a|
            type_str = a.list? ? "list_of(#{a.type})" : a.type.to_s
            { name: a.name, type: type_str, default: a.default }
          end
        end

        def serialize_commands(agg)
          agg.commands.map { |c| serialize_command(c) }
        end

        def serialize_command(cmd)
          actor = cmd.respond_to?(:actors) && !cmd.actors.empty? ? cmd.actors.first : nil
          role = actor.respond_to?(:name) ? actor.name : actor.to_s if actor
          refs = cmd.respond_to?(:references) ? Array(cmd.references) : []
          {
            name: cmd.name,
            role: role,
            description: cmd.respond_to?(:description) ? cmd.description : nil,
            emits: cmd.respond_to?(:emits) ? cmd.emits : nil,
            attributes: cmd.attributes.map { |a| { name: a.name, type: a.type.to_s } },
            references: refs.map { |r| { name: r.name.to_s, target: (r.respond_to?(:type) ? r.type : r.target).to_s } },
            givens: cmd.givens.map { |g| { message: g.message } },
            mutations: cmd.mutations.map { |m| serialize_mutation(m) }
          }
        end

        def serialize_mutation(m)
          { field: m.field.to_s, operation: m.operation.to_s, value: m.value.to_s }
        end

        def serialize_events(agg)
          return [] unless agg.respond_to?(:events)
          Array(agg.events).map { |e| e.respond_to?(:name) ? e.name : e.to_s }
        end

        def serialize_value_objects(agg)
          agg.value_objects.map do |vo|
            {
              name: vo.name,
              attributes: vo.attributes.map { |a| { name: a.name, type: a.type.to_s } }
            }
          end
        end

        def serialize_references(agg)
          return [] unless agg.respond_to?(:references)
          Array(agg.references).map { |r| r.respond_to?(:type) ? r.type.to_s : r.name.to_s }
        end

        def serialize_lifecycle(agg)
          return nil unless agg.respond_to?(:lifecycle) && agg.lifecycle
          lc = agg.lifecycle
          {
            field: lc.field.to_s,
            default: lc.default,
            states: lc.states,
            transitions: lc.transitions.map do |cmd, t|
              { command: cmd, target: t.target, from: t.from }
            end
          }
        end

        def serialize_fixtures(agg)
          return [] unless @domain.respond_to?(:fixtures)
          Array(@domain.fixtures).select { |f| f[:aggregate] == agg.name }.map do |f|
            attrs = f.reject { |k, _| k == :aggregate }
            id = attrs[:id] || attrs[:name] || "#{agg.name}-#{attrs.hash.abs}"
            attrs.merge(id: id.to_s)
          end
        end

        def serialize_policy(p)
          { name: p.name, event: p.event_name, trigger: p.trigger_command }
        end
      end
    end
  end
end
