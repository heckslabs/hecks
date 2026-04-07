# Hecks::CLI::DomainInspector::AggregateFormatter::BehaviorFormatters
#
# Formats the behavioral elements of an aggregate: commands, events, and
# queries. Mixed into AggregateFormatter to keep concerns separated.
#
#   include BehaviorFormatters
#
module Hecks
  class CLI
    class DomainInspector
      class AggregateFormatter
        # Hecks::CLI::DomainInspector::AggregateFormatter::BehaviorFormatters
        #
        # Formats behavioral aggregate elements: commands, events, and queries for terminal output.
        #
        module BehaviorFormatters
          private

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
        end
      end
    end
  end
end
