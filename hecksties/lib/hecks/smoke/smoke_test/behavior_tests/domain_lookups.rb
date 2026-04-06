# HecksTemplating::SmokeTest::DomainLookups
#
# Helper methods for looking up commands and events in the domain IR.
# Used by policy tests and workflow tests to resolve cross-references.
#
#   find_command_by_event("PizzaCreated")  #=> Command or nil
#   find_event_name("CreatePizza")         #=> "PizzaCreated" or nil
#
module HecksTemplating
  class SmokeTest
    module DomainLookups
      private

      # Returns the command that emits this event, or nil if it's
      # from another domain (cross-domain policy trigger).
      def find_command_by_event(event_name)
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, i|
            return cmd if agg.events[i]&.name == event_name
          end
        end
        nil
      end

      def find_event_name(command_name)
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, i|
            return agg.events[i]&.name if cmd.name == command_name
          end
        end
        nil
      end

      def find_workflow_first_cmd(wf)
        return nil if wf.steps.empty?
        cmd_name = wf.steps.first[:command] || wf.steps.first["command"]
        return nil unless cmd_name
        @domain.aggregates.each do |agg|
          cmd = agg.commands.find { |c| c.name == cmd_name }
          return cmd if cmd
        end
        nil
      end

      def build_service_data(svc)
        svc.attributes.each_with_object({}) { |a, h| h[a.name.to_s] = sample_value(a) }
      end
    end
  end
end
