
module Hecks
  class Workshop
    # Hecks::Workshop::Presenter
    #
    # Session mixin for human-readable output: describe, status, and inspect.
    # Part of the Session layer -- formats aggregate, command, policy, query,
    # scope, and subscriber summaries for REPL display.
    #
    # The +describe+ method prints a complete domain overview including all
    # aggregates with their attributes, value objects, entities, commands,
    # validations, policies, queries, scopes, and subscribers. Domain-level
    # policies (cross-aggregate) are shown separately at the end.
    #
    #   workshop.describe   # prints full domain summary
    #   workshop.status     # alias for describe
    #
    module Presenter
      include HecksTemplating::NamingHelpers
      # Print a full description of the domain and all its aggregates.
      #
      # Builds the domain, then iterates each aggregate printing its
      # attributes, value objects, entities, commands (with event mappings),
      # validations, policies, queries, scopes, and subscribers. Also
      # prints domain-level policies at the end if any exist.
      #
      # @return [nil]
      def describe
        domain = to_domain

        lines = []
        lines << "#{@name} Domain"
        lines << ""

        domain.aggregates.each do |agg|
          handle = @handles[agg.name] || AggregateHandle.new(agg.name, @aggregate_builders[agg.name], domain_module: bluebook_module_name(@name))
          lines << "  #{agg.name}"

          unless agg.attributes.empty?
            attrs = agg.attributes.map { |a| "#{a.name} (#{Hecks::Utils.type_label(a)})" }.join(", ")
            lines << "    Attributes: #{attrs}"
          end

          unless (agg.references || []).empty?
            refs = agg.references.map { |r| "#{r.name} (#{r.type})" }.join(", ")
            lines << "    References: #{refs}"
          end

          unless agg.value_objects.empty?
            agg.value_objects.each do |vo|
              vo_attrs = vo.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
              lines << "    Value Objects: #{vo.name} (#{vo_attrs})"
            end
          end

          unless agg.entities.empty?
            agg.entities.each do |ent|
              ent_attrs = ent.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
              lines << "    Entities: #{ent.name} (#{ent_attrs})"
            end
          end

          unless agg.commands.empty?
            agg.commands.each_with_index do |cmd, i|
              event = agg.events[i]
              lines << "    Commands: #{cmd.name} -> #{event&.name}"
            end
          end

          unless agg.validations.empty?
            vals = agg.validations.map { |v| "#{v.field} (#{v.rules.keys.join(', ')})" }.join(", ")
            lines << "    Validations: #{vals}"
          end

          unless agg.policies.empty?
            agg.policies.each do |pol|
              lines << "    Policies: #{pol.name} (on #{pol.event_name} -> #{pol.trigger_command})"
            end
          end

          unless agg.queries.empty?
            queries = agg.queries.map(&:name).join(", ")
            lines << "    Queries: #{queries}"
          end

          unless agg.scopes.empty?
            scopes = agg.scopes.map(&:name).join(", ")
            lines << "    Scopes: #{scopes}"
          end

          unless agg.subscribers.empty?
            subs = agg.subscribers.map { |s| "on #{s.event_name}" }.join(", ")
            lines << "    Subscribers: #{subs}"
          end

          lines << ""
        end

        unless domain.policies.empty?
          lines << "  Domain Policies:"
          domain.policies.each do |pol|
            lines << "    #{pol.name} (on #{pol.event_name} -> #{pol.trigger_command})"
          end
          lines << ""
        end

        puts lines.join("\n")
        nil
      end

      # Print current domain state. Alias for describe.
      #
      # @return [nil]
      def status
        describe
      end

      # Return a compact string representation of the workshop.
      #
      # @return [String] e.g. '#<Hecks::Workshop "Pizzas" [play] (3 aggregates)>'
      def inspect
        mode_label = play? ? "play" : "sketch"
        "#<Hecks::Workshop \"#{@name}\" [#{mode_label}] (#{@aggregate_builders.size} aggregates)>"
      end
    end
  end
end
