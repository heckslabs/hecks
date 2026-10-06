module Hecks
  module Doors
    class McpDoorScope
      # What is wrong with the `HECKS_DOOR_*` variables a door was spawned with, as the sentences
      # that refuse to start it.
      module EnvProblems
        module_function

        # Every problem in `env`: a variable the door does not take, then those of the mode.
        def setting_problems(env)
          known = [TOOLS_VARIABLE, DOMAINS_VARIABLE, COMMANDS_VARIABLE]
          problems = (env.keys.select { |name| name.start_with?(ENV_PREFIX) } - known).map do |name|
            "environment #{name} is not accepted; the door takes only #{known.join(", ")}"
          end
          problems + mode_problems(env[TOOLS_VARIABLE], env[DOMAINS_VARIABLE], env[COMMANDS_VARIABLE])
        end

        def mode_problems(tools, domains, commands)
          return stray_problems(domains, commands) if tools.nil?
          unless MODES.include?(tools)
            return ["#{TOOLS_VARIABLE}=#{tools.inspect} is not accepted; the values are #{MODES.map(&:inspect).join(" and ")}"]
          end

          problems = []
          if split_paths(domains.to_s).empty?
            problems << "#{TOOLS_VARIABLE}=#{tools} needs #{DOMAINS_VARIABLE}, the domains this door may read"
          end
          problems + command_problems(tools, commands)
        end

        def stray_problems(domains, commands)
          stray = { DOMAINS_VARIABLE => domains, COMMANDS_VARIABLE => commands }.compact.keys
          return [] if stray.empty?

          ["#{stray.join(" and ")} set without #{TOOLS_VARIABLE}=#{READERS} or #{TOOLS_VARIABLE}=#{COMMANDS}; " \
           "they only narrow a restricted door"]
        end

        def command_problems(tools, commands)
          if tools == COMMANDS && split_names(commands).empty?
            ["#{TOOLS_VARIABLE}=#{COMMANDS} needs #{COMMANDS_VARIABLE}, the commands this door may dispatch"]
          elsif tools == READERS && !commands.nil?
            ["#{COMMANDS_VARIABLE} is set in reader mode; it only narrows a commands door"]
          else
            []
          end
        end

        def split_paths(value) = value.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)

        def split_names(value) = value.to_s.split(",").map(&:strip).reject(&:empty?).uniq
      end
    end
  end
end
