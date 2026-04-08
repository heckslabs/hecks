# Hecks::Capabilities::ChatAgent::ToolBuilder
#
# Generates tool definitions from the full domain IR. Walks all aggregates'
# commands, queries, and domain-level services and workflows. Each becomes
# a tool the LLM can call. Uses .description wherever available.
#
#   tools = ToolBuilder.build(domain)
#   tools.first
#   # => { name: "CreatePizza", description: "...",
#   #      parameters: [{ name: "name", type: "string", required: true }] }
#
module Hecks
  module Capabilities
    module ChatAgent
      module ToolBuilder
        # Build tool definitions from the full domain surface.
        #
        # @param domain [BluebookModel::Structure::Domain] the domain
        # @return [Array<Hash>] tool definitions
        def self.build(domain)
          tools = []
          domain.aggregates.each do |agg|
            agg.commands.each { |cmd| tools << command_tool(agg, cmd) }
            agg.queries.each  { |q|   tools << query_tool(agg, q) }
          end
          domain.services.each  { |svc| tools << service_tool(svc) }
          domain.workflows.each { |wf|  tools << workflow_tool(wf) }
          tools
        end

        def self.command_tool(agg, cmd)
          desc = cmd.description || "Execute #{cmd.name} on #{agg.name}"
          {
            name: cmd.name,
            description: desc,
            parameters: cmd.attributes.map { |a| param(a) }
          }
        end

        def self.query_tool(agg, query)
          {
            name: query.name,
            description: "Query #{agg.name}: #{query.name}",
            parameters: []
          }
        end

        def self.service_tool(svc)
          desc = svc.description || "Run service #{svc.name}"
          {
            name: svc.name,
            description: desc,
            parameters: svc.attributes.map { |a| param(a) }
          }
        end

        def self.workflow_tool(wf)
          desc = wf.description || "Run workflow #{wf.name}"
          {
            name: wf.name,
            description: desc,
            parameters: []
          }
        end

        def self.param(attr)
          { name: attr.name.to_s, type: json_type(attr), required: true }
        end

        def self.json_type(attr)
          case attr.ruby_type
          when "Integer" then "integer"
          when "Float"   then "number"
          when "Array"   then "array"
          when "JSON"    then "object"
          else "string"
          end
        end

        private_class_method :command_tool, :query_tool, :service_tool,
                             :workflow_tool, :param, :json_type
      end
    end
  end
end
