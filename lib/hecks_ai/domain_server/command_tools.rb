module Hecks
  module MCP
    class DomainServer
      # Hecks::MCP::DomainServer::CommandTools
      #
      # Mixin that registers MCP tools for domain commands. Each command on each
      # aggregate becomes a callable MCP tool with a typed JSON Schema input.
      #
      # When a tool is invoked, it translates the JSON arguments into keyword
      # arguments and calls the corresponding method on the generated aggregate
      # class. The result is serialized back to a human-readable string.
      #
      # Mixed into DomainServer -- expects the following instance state:
      #   - +@server+ [MCP::Server] -- the MCP server to register tools on
      #   - +@domain+ [Hecks::DomainModel::Structure::Domain] -- the domain model
      #   - +@mod+ [Module] -- the generated domain module (e.g. PizzasDomain)
      #
      # Also expects these helper methods from DomainServer:
      #   - +derive_method_name(cmd_name, agg_name)+ -- maps command name to method symbol
      #   - +json_type(attr)+ -- converts a domain attribute to a JSON Schema type
      #   - +serialize_aggregate(obj)+ -- formats a domain object as a readable string
      #
      module CommandTools
        include HecksTemplating::NamingHelpers
        private

        # Iterates all aggregates in the domain and registers each of their
        # commands as an MCP tool.
        #
        # @return [void]
        def register_command_tools
          @domain.aggregates.each do |agg|
            agg_class = @mod.const_get(domain_constant_name(agg.name))
            agg.commands.each do |cmd|
              register_command(agg, agg_class, cmd)
            end
          end
        end

        # Registers a single command as an MCP tool. Builds a JSON Schema from
        # the command's attributes and wires the tool to call the corresponding
        # class method on the aggregate.
        #
        # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate owning the command
        # @param agg_class [Class] the generated Ruby class for the aggregate
        # @param cmd [Hecks::DomainModel::Behavior::Command] the command to register
        # @return [void]
        def register_command(agg, agg_class, cmd)
          method_name = derive_method_name(cmd.name, agg.name)
          props = cmd.attributes.each_with_object({}) do |attr, h|
            desc = "#{attr.name} (#{attr.ruby_type}, required)"
            desc += ". Allowed values: #{attr.enum.join(', ')}" if attr.enum
            desc += ". Example: #{example_value(attr)}"
            h[attr.name.to_s] = { type: json_type(attr), description: desc }
            h[attr.name.to_s][:enum] = attr.enum if attr.enum
          end
          required = cmd.attributes.map { |a| a.name.to_s }
          klass = agg_class
          description = build_command_description(agg, cmd, required)

          @server.define_tool(
            name: cmd.name,
            description: description,
            input_schema: { type: "object", properties: props, required: required }
          ) do |args|
            attrs = args.transform_keys(&:to_sym)
            result = klass.send(method_name, **attrs)
            serialize_aggregate(result)
          end
        end

        # Builds a rich description for a command tool including what it does,
        # required attributes, emitted event, guard info, and return shape.
        #
        # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate
        # @param cmd [Hecks::DomainModel::Behavior::Command] the command
        # @param required [Array<String>] required parameter names
        # @return [String] the full description
        def build_command_description(agg, cmd, required)
          parts = []
          parts << "Executes the #{cmd.name} command on the #{agg.name} aggregate."
          parts << "Required attributes: #{required.join(', ')}." unless required.empty?
          parts << "Emits event: #{cmd.inferred_event_name}."
          parts << "Guard: #{cmd.guard_name} (may reject the command)." if cmd.guard_name
          if cmd.preconditions.any?
            parts << "Preconditions: #{cmd.preconditions.map(&:description).compact.join('; ')}."
          end
          attr_list = agg.attributes.map { |a| "#{a.name}: #{a.ruby_type}" }.join(", ")
          parts << "Returns: JSON object with #{agg.name} fields (#{attr_list}, id, created_at, updated_at)."
          parts.join(" ")
        end

        # Returns a representative example value for a domain attribute,
        # suitable for inclusion in a tool description.
        #
        # @param attr [Hecks::DomainModel::Structure::Attribute] the attribute
        # @return [String] an example value
        def example_value(attr)
          return attr.enum.first if attr.enum
          case attr.ruby_type
          when "Integer" then "42"
          when "Float" then "9.99"
          when "Date" then "2025-01-15"
          when "DateTime" then "2025-01-15T10:30:00Z"
          when "JSON" then '{"key": "value"}'
          else "\"example_#{attr.name}\""
          end
        end
      end
    end
  end
end
