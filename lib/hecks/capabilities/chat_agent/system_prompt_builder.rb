# Hecks::Capabilities::ChatAgent::SystemPromptBuilder
#
# Generates a system prompt from the domain IR. Walks all aggregates,
# commands, events, policies, lifecycles, queries, and domain-level
# services and workflows. Uses .description from the Describable mixin
# wherever available.
#
#   prompt = SystemPromptBuilder.build(domain)
#   # => "You are an AI assistant for the Pizzas domain.\n\n## Pizza\n..."
#
module Hecks
  module Capabilities
    module ChatAgent
      module SystemPromptBuilder
        # Build a system prompt from the full domain IR.
        #
        # @param domain [DomainModel::Structure::Domain] the domain
        # @return [String] the assembled system prompt
        def self.build(domain)
          lines = []
          lines << "You are an AI assistant for the #{domain.name} domain."
          lines << domain.description if domain.description

          domain.aggregates.each { |agg| lines.concat(aggregate_section(agg)) }
          lines.concat(services_section(domain.services)) if domain.services.any?
          lines.concat(workflows_section(domain.workflows)) if domain.workflows.any?
          lines << ""
          lines << "Use the provided tools to execute actions. Do not fabricate data."
          lines.join("\n")
        end

        def self.aggregate_section(agg)
          lines = ["", "## #{agg.name}"]
          lines << agg.description if agg.description
          lines << "Attributes: #{agg.attributes.map { |a| "#{a.name} (#{a.ruby_type})" }.join(', ')}"

          agg.commands.each do |cmd|
            desc = cmd.description ? " -- #{cmd.description}" : ""
            attrs = cmd.attributes.map { |a| "#{a.name}: #{a.ruby_type}" }.join(", ")
            lines << "- Command: #{cmd.name}(#{attrs})#{desc}"
          end

          agg.events.each do |evt|
            desc = evt.description ? " -- #{evt.description}" : ""
            lines << "- Event: #{evt.name}#{desc}"
          end

          agg.policies.each do |pol|
            desc = pol.description ? " -- #{pol.description}" : ""
            lines << "- Policy: #{pol.name} (on #{pol.event_name} -> #{pol.trigger_command})#{desc}"
          end

          if agg.lifecycle
            lc = agg.lifecycle
            desc = lc.description ? " -- #{lc.description}" : ""
            transitions = lc.transitions.map { |cmd, val|
              target = val.respond_to?(:target) ? val.target : val.to_s
              from = val.respond_to?(:from) ? val.from : nil
              from ? "#{from} -[#{cmd}]-> #{target}" : "-[#{cmd}]-> #{target}"
            }.join(", ")
            lines << "- Lifecycle: #{lc.field} [#{transitions}]#{desc}"
          end

          agg.queries.each do |q|
            lines << "- Query: #{q.name}"
          end

          lines
        end

        def self.services_section(services)
          lines = ["", "## Services"]
          services.each do |svc|
            desc = svc.description ? " -- #{svc.description}" : ""
            attrs = svc.attributes.map { |a| "#{a.name}: #{a.ruby_type}" }.join(", ")
            lines << "- #{svc.name}(#{attrs})#{desc}"
          end
          lines
        end

        def self.workflows_section(workflows)
          lines = ["", "## Workflows"]
          workflows.each do |wf|
            desc = wf.description ? " -- #{wf.description}" : ""
            steps = wf.steps.map { |s| s[:command] || "branch" }.join(" -> ")
            lines << "- #{wf.name}: #{steps}#{desc}"
          end
          lines
        end

        private_class_method :aggregate_section, :services_section, :workflows_section
      end
    end
  end
end
