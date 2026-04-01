module Hecks
  class Workshop
    class WebRunner
      # Hecks::Workshop::WebRunner::StateSerializer
      #
      # Serializes the current workshop state into a JSON-ready hash for
      # the browser console. Includes domain tree (aggregates with their
      # attributes, commands, events, etc.) and event log when in play mode.
      #
      #   StateSerializer.new(workshop).serialize
      #   # => { mode: "sketch", domain_name: "Pizzas", aggregates: [...], events: [] }
      #
      class StateSerializer
        def initialize(workshop, domain_groups: {}, domains: [])
          @workshop = workshop
          @domain_groups = domain_groups
          @domains = domains
        end

        def serialize
          aggs = serialize_aggregates
          {
            mode:        @workshop.play? ? "play" : "sketch",
            domain_name: @workshop.name,
            aggregates:  aggs,
            services:    serialize_services,
            policy_flows: build_policy_flows(aggs),
            events:      serialize_events,
            mermaid:     build_mermaid(aggs)
          }
        end

        private

        def serialize_aggregates
          @workshop.aggregate_builders.values.map do |builder|
            agg = builder.build
            {
              name:           agg.name,
              domain:         @domain_groups[agg.name],
              attributes:     serialize_attrs(agg),
              commands:       agg.commands.map { |c|
                { name: c.name, attributes: c.attributes.map { |a|
                  { name: a.name, type: a.type.to_s }
                }}
              },
              events:         agg.events.map(&:name),
              value_objects:  serialize_value_objects(agg),
              entities:       serialize_entities(agg),
              policies:       agg.policies.map { |p|
                { name: p.name, event: p.event_name, trigger: p.trigger_command }
              },
              queries:        agg.queries.map(&:name),
              specifications: agg.specifications.map(&:name),
              references_to:  (agg.references || []).map { |r|
                { name: r[:name], type: r[:type], kind: r[:kind]&.to_s, domain: r[:domain] }
              },
              lifecycle:      serialize_lifecycle(agg),
              subscribers:    serialize_subscribers(agg)
            }
          end
        end

        def serialize_attrs(agg)
          attrs = agg.attributes.map { |a| format_attr(a) }
          (agg.references || []).each do |ref|
            attrs << { name: ref.name, type: "reference_to(#{ref.type})" }
          end
          attrs
        end

        def format_attr(a)
          type_str = if a.list?
                       "list_of(#{a.type})"
                     else
                       a.type.to_s
                     end
          { name: a.name, type: type_str }
        end

        def serialize_value_objects(agg)
          agg.value_objects.map do |vo|
            { name: vo.name, attributes: vo.attributes.map { |a| format_attr(a) } }
          end
        end

        def serialize_entities(agg)
          agg.entities.map do |ent|
            { name: ent.name, attributes: ent.attributes.map { |a| format_attr(a) } }
          end
        end

        def serialize_lifecycle(agg)
          orig = find_original_aggregate(agg.name)
          lc = orig&.lifecycle
          return nil unless lc
          {
            field:   lc.field.to_s,
            default: lc.default,
            states:  lc.states,
            transitions: lc.transitions.map { |cmd, t|
              { command: cmd, target: t.target, from: t.from }
            }
          }
        end

        def serialize_subscribers(agg)
          orig = find_original_aggregate(agg.name)
          return [] unless orig
          orig.subscribers.map do |sub|
            { name: sub.name, event: sub.event_name, async: sub.async }
          end
        end

        def serialize_services
          @domains.flat_map do |domain|
            domain.services.map do |svc|
              { name: svc.name, domain: domain.name,
                attributes: svc.attributes.map { |a| { name: a.name, type: a.type.to_s } } }
            end
          end
        rescue
          []
        end

        def find_original_aggregate(name)
          @domains.each do |domain|
            agg = domain.aggregates.find { |a| a.name == name }
            return agg if agg
          end
          nil
        end

        def build_policy_flows(aggs)
          # Build event→aggregate lookup: which aggregate produces which event?
          event_source = {}
          aggs.each do |agg|
            agg[:events].each { |e| event_source[e] = agg[:name] }
          end

          flows = []
          aggs.each do |agg|
            next unless agg[:policies].is_a?(Array)
            agg[:policies].each do |pol|
              next unless pol.is_a?(Hash) && pol[:event]
              source = event_source[pol[:event]]
              next unless source && source != agg[:name]
              flows << {
                from: source, to: agg[:name],
                event: pol[:event], trigger: pol[:trigger],
                policy: pol[:name]
              }
            end
          end
          flows
        end

        def build_mermaid(aggs)
          lines = ["graph LR"]
          agg_names = aggs.map { |a| a[:name] }
          aggs.each do |agg|
            count = agg[:attributes].size
            cmds = agg[:commands].size
            lines << "  #{agg[:name]}[\"#{agg[:name]}<br/><small>#{count} attrs · #{cmds} cmds</small>\"]"
          end
          aggs.each do |agg|
            agg[:attributes].each do |a|
              if a[:type].to_s.include?("reference_to")
                target = a[:type].to_s.gsub(/reference_to\(|\)|"/, "").strip
                label = a[:name].to_s.sub(/_id$/, "")
                lines << "  #{agg[:name]} -->|#{label}| #{target}" if agg_names.include?(target)
              elsif a[:type].to_s.include?("list_of")
                target = a[:type].to_s.gsub(/list_of\(|\)|"/, "").strip
                label = a[:name].to_s.sub(/_id$/, "")
                lines << "  #{agg[:name]} -.->|#{label}| #{target}" if agg_names.include?(target)
              end
            end
          end
          lines.join("\n")
        end

        def serialize_events
          return [] unless @workshop.play? && @workshop.playground
          @workshop.playground.events.map do |e|
            attrs = {}
            e.class.instance_methods(false).each do |m|
              next if %i[occurred_at aggregate_id].include?(m)
              attrs[m] = e.send(m).inspect rescue nil
            end
            event_name = Hecks::Utils.const_short_name(e)
            command_name = event_name
              .sub(/\ACanceled/, "Cancel")
              .sub(/\ACreated/, "Create")
              .sub(/\AUpdated/, "Update")
              .sub(/\ADeleted/, "Delete")
              .sub(/\AAdded/, "Add")
              .sub(/\ARemoved/, "Remove")
              .sub(/\APlaced/, "Place")
            { type: event_name, command: command_name, occurred_at: e.occurred_at&.to_s,
              aggregate_id: e.respond_to?(:aggregate_id) ? e.aggregate_id : nil,
              data: attrs }
          end
        end
      end
    end
  end
end
