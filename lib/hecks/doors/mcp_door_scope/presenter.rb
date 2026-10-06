module Hecks
  module Doors
    class McpDoorScope
      # A tool definition as `tools/list` shows it to one door, and the notes the door starts with.
      module Presenter
        module_function

        # The tool as `tools/list` shows it. A door that serves one domain makes `domain:` optional.
        # On a commands door, `dispatch` also names the commands it serves as an enum, so a caller
        # sees them as typed choices instead of finding out by being refused, and says what each
        # takes and which role it declares.
        #
        # @param scope [McpDoorScope] the door's scope
        # @param tool [Hash] a tool definition from `McpDoor::TOOLS`
        # @param guide [Array<String>, nil] one line per allowed command
        #   (`Storehouse.command_guide`)
        # @return [Hash] the definition, narrowed for this door
        def present(scope, tool, guide)
          tool = domain_optional(tool, scope.default_domain) if scope.default_domain
          return tool unless scope.commands_mode? && tool[:name] == "dispatch"

          narrow_dispatch(tool, guide, scope.allowed_commands)
        end

        # `dispatch`, with the commands the door serves as typed choices.
        def narrow_dispatch(tool, guide, commands)
          properties = tool[:inputSchema][:properties]
          steps      = properties[:steps]
          narrowed   = properties.merge(command: with_enum(properties[:command], commands),
                                        steps:   steps.merge(items: step_items(steps[:items], commands)))
          tool.merge(description: dispatch_description(tool[:description], guide, commands),
                     inputSchema: tool[:inputSchema].merge(properties: narrowed))
        end

        def domain_optional(tool, default)
          schema = tool[:inputSchema]
          return tool unless schema[:properties].key?(:domain)

          note = "Optional: this door serves one domain, #{default}, and uses it when you leave this out."
          properties = schema[:properties].merge(domain: schema[:properties][:domain].merge(description: note))
          tool.merge(inputSchema: schema.merge(properties: properties, required: schema[:required] - ["domain"]))
        end

        def dispatch_description(base, guide, commands)
          intro = "#{base} This door dispatches only the commands below, each with the role it declares: pass " \
                  "that role as `role`. A command that takes `run` takes a key you choose, and the call answers " \
                  "the record as it stands once its reactions have run; an argument marked * is required."
          entries = Array(guide).empty? ? commands : guide
          ([intro] + entries.map { |entry| "- #{entry}" }).join("\n")
        end

        def with_enum(property, commands)
          property.merge(enum: commands)
        end

        def step_items(items, commands)
          items.merge(properties: items[:properties].merge(command: with_enum(items[:properties][:command], commands)))
        end

        # What a reader door says about itself when it starts.
        def reader_notes(domains)
          ["Reader mode (#{TOOLS_VARIABLE}=#{READERS}): serves #{READER_TOOLS.join(", ")}; " \
           "refuses dispatch (with dry_run and steps), behaviors and every other tool.",
           "domain: boots only #{DOMAINS_VARIABLE}: #{domains.join(", ")}.",
           "Reader mode limits reach and identifies no one; it is not authentication."]
        end

        # What a commands door says about itself when it starts.
        def commands_notes(domains, commands)
          ["Commands mode (#{TOOLS_VARIABLE}=#{COMMANDS}): serves #{READER_TOOLS.join(", ")} and dispatch of only " \
           "#{COMMANDS_VARIABLE}: #{commands.join(", ")}; refuses behaviors and every other tool.",
           "domain: boots only #{DOMAINS_VARIABLE}: #{domains.join(", ")}.",
           "Commands mode limits reach and identifies no one; role: stays self-asserted and it is not authentication."]
        end
      end
    end
  end
end
