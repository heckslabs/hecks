module Hecks
  module Adapters
    module Driving
      class McpScope
        # What is wrong with the `HECKS_SERVER_*` variables a server was spawned with, as the
        # sentences that refuse to start it.
        module EnvProblems
          module_function

          # Variables under this prefix are retired spellings of the `HECKS_SERVER_*` ones.
          RETIRED_PREFIX = "HECKS_DOOR_".freeze

          # Every problem in `env`: a variable the server does not take, then those of the mode.
          def setting_problems(env)
            known = [TOOLS_VARIABLE, DOMAINS_VARIABLE, COMMANDS_VARIABLE]
            problems = retired_problems(env) + (env.keys.select { |name| name.start_with?(ENV_PREFIX) } - known).map do |name|
              "environment #{name} is not accepted; the server takes only #{known.join(", ")}"
            end
            problems + mode_problems(env[TOOLS_VARIABLE], env[DOMAINS_VARIABLE], env[COMMANDS_VARIABLE])
          end

          # A variable under the retired prefix is refused, never ignored: ignoring
          # `HECKS_DOOR_TOOLS`
          # would start an unrestricted server where the spawner asked for a narrow one.
          def retired_problems(env)
            env.keys.select { |name| name.start_with?(RETIRED_PREFIX) }.map do |name|
              "environment #{name} is retired; the server reads #{name.sub(RETIRED_PREFIX, ENV_PREFIX)}"
            end
          end

          def mode_problems(tools, domains, commands)
            return stray_problems(domains, commands) if tools.nil?
            unless MODES.include?(tools)
              return ["#{TOOLS_VARIABLE}=#{tools.inspect} is not accepted; the values are #{MODES.map(&:inspect).join(" and ")}"]
            end

            problems = []
            if split_paths(domains.to_s).empty?
              problems << "#{TOOLS_VARIABLE}=#{tools} needs #{DOMAINS_VARIABLE}, the domains this server may read"
            end
            problems + command_problems(tools, commands)
          end

          def stray_problems(domains, commands)
            stray = { DOMAINS_VARIABLE => domains, COMMANDS_VARIABLE => commands }.compact.keys
            return [] if stray.empty?

            ["#{stray.join(" and ")} set without #{TOOLS_VARIABLE}=#{READERS} or #{TOOLS_VARIABLE}=#{COMMANDS}; " \
             "they only narrow a restricted server"]
          end

          def command_problems(tools, commands)
            if tools == COMMANDS && split_names(commands).empty?
              ["#{TOOLS_VARIABLE}=#{COMMANDS} needs #{COMMANDS_VARIABLE}, the commands this server may dispatch"]
            elsif tools == READERS && !commands.nil?
              ["#{COMMANDS_VARIABLE} is set in reader mode; it only narrows a commands server"]
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
end
