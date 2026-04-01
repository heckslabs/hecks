# Hecks::CLI::DomainInspector::AggregateFormatter
#
# Formats a single aggregate from the domain IR into readable terminal output.
# Covers attributes, value objects, entities, lifecycle, commands, events,
# queries, validations, invariants, policies, scopes, specifications,
# subscribers, computed attributes, and references.
#
#   formatter = AggregateFormatter.new(aggregate)
#   formatter.format  # => Array<String>
#
require_relative "secondary_formatters"

module Hecks
  class CLI
    class DomainInspector
      class AggregateFormatter
        include SecondaryFormatters

        # @param agg [Hecks::DomainModel::Structure::Aggregate]
        def initialize(agg)
          @agg = agg
        end

        # @return [Array<String>] formatted lines for this aggregate
        def format
          lines = []
          lines << "Aggregate: #{@agg.name}"
          lines << "=" * (11 + @agg.name.length)
          lines << ""
          lines.concat(format_attributes)
          lines.concat(format_computed_attributes)
          lines.concat(format_value_objects)
          lines.concat(format_entities)
          lines.concat(format_lifecycle)
          lines.concat(format_commands)
          lines.concat(format_events)
          lines.concat(format_queries)
          lines.concat(format_validations)
          lines.concat(format_invariants)
          lines.concat(format_policies)
          lines.concat(format_scopes)
          lines.concat(format_specifications)
          lines.concat(format_subscribers)
          lines.concat(format_references)
          lines
        end

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

        def format_lifecycle
          lc = @agg.lifecycle
          return [] unless lc
          lines = ["  Lifecycle:"]
          lines << "    field: #{lc.field}, default: #{lc.default.inspect}"
          lines << "    states: #{lc.states.join(', ')}"
          lines << "    transitions:"
          lc.transitions.each do |cmd, transition|
            if transition.respond_to?(:constrained?) && transition.constrained?
              lines << "      #{cmd} -> #{transition.target} (from: #{transition.from})"
            else
              target = transition.respond_to?(:target) ? transition.target : transition.to_s
              lines << "      #{cmd} -> #{target}"
            end
          end
          lines << ""
        end

        def format_commands
          return [] if @agg.commands.empty?
          lines = ["  Commands:"]
          @agg.commands.each_with_index do |cmd, i|
            event = @agg.events[i]
            params = cmd.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
            event_info = event ? " -> emits #{event.name}" : ""
            lines << "    #{cmd.name}(#{params})#{event_info}"
            cmd.preconditions.each { |c| lines << "      precondition: #{c.message}" }
            cmd.postconditions.each { |c| lines << "      postcondition: #{c.message}" }
            if cmd.call_body
              lines << "      body: #{Hecks::Utils.block_source(cmd.call_body)}"
            end
          end
          lines << ""
        end

        def format_events
          return [] if @agg.events.compact.empty?
          lines = ["  Events:"]
          @agg.events.compact.each do |ev|
            attrs = ev.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
            lines << "    #{ev.name}(#{attrs})"
          end
          lines << ""
        end

        def format_queries
          return [] if @agg.queries.empty?
          lines = ["  Queries:"]
          @agg.queries.each do |q|
            body = Hecks::Utils.block_source(q.block)
            lines << "    #{q.name}: #{body}"
          end
          lines << ""
        end

        def format_validations
          return [] if @agg.validations.empty?
          lines = ["  Validations:"]
          @agg.validations.each do |v|
            rules = v.rules.map { |k, val| "#{k}: #{val}" }.join(", ")
            lines << "    #{v.field}: #{rules}"
          end
          lines << ""
        end

        def format_invariants
          return [] if @agg.invariants.empty?
          lines = ["  Invariants:"]
          @agg.invariants.each do |inv|
            body = Hecks::Utils.block_source(inv.block)
            lines << "    #{inv.message}: #{body}"
          end
          lines << ""
        end

        def format_policies
          return [] if @agg.policies.empty?
          lines = ["  Policies:"]
          @agg.policies.each do |pol|
            lines << format_policy(pol)
          end
          lines << ""
        end

        def format_policy(pol)
          async_note = pol.async ? " [async]" : ""
          if pol.reactive?
            cond = pol.condition ? " when #{Hecks::Utils.block_source(pol.condition)}" : ""
            "    #{pol.name}: #{pol.event_name} -> #{pol.trigger_command}#{async_note}#{cond}"
          else
            body = Hecks::Utils.block_source(pol.block)
            "    #{pol.name}: guard#{async_note} — #{body}"
          end
        end
      end
    end
  end
end
