require_relative "../runtime/errors"

module Hecks
  module Doors
    # What a spawned hecks mcp may do: every tool by default; only reader tools against named
    # domains in reader mode; and in commands mode those plus `dispatch` of a closed list of
    # commands — reach, not identity (ADR 0072, ADR 0089).
    class McpDoorScope
      ENV_PREFIX         = "HECKS_DOOR_".freeze
      TOOLS_VARIABLE     = "HECKS_DOOR_TOOLS".freeze
      DOMAINS_VARIABLE   = "HECKS_DOOR_DOMAINS".freeze
      COMMANDS_VARIABLE  = "HECKS_DOOR_COMMANDS".freeze
      READERS            = "readers".freeze
      COMMANDS           = "commands".freeze
      MODES              = [READERS, COMMANDS].freeze
      EXIT_STATUS        = 2

      # The tools a reader door serves — each reads a domain or the door's own
      # audit log and writes no domain state. `validate` still boots its
      # domain, so it stays bound to the allowed set like every other tool.
      READER_TOOLS = %w[query events state catalog describe validate domains history follow].freeze

      # The tools a commands door serves: the reader tools, and `dispatch` for the allowed commands.
      COMMAND_TOOLS = (READER_TOOLS + %w[dispatch]).freeze

      # Unrestricted when no HECKS_DOOR_* variable is set.
      def self.from_env(env = ENV)
        problems = setting_problems(env)
        raise ArgumentError, problems.join("\n") unless problems.empty?
        return new(allowed_domains: nil) unless env[TOOLS_VARIABLE]

        commands = env[TOOLS_VARIABLE] == COMMANDS ? split_names(env[COMMANDS_VARIABLE]) : nil
        new(allowed_domains: split_paths(env[DOMAINS_VARIABLE]), allowed_commands: commands)
      end

      # Refuses to stderr, not stdout, which carries the MCP protocol.
      def self.start!(server:, env: ENV, stderr: $stderr)
        from_env(env)
      rescue ArgumentError, Runtime::TypeMismatch => e
        e.message.each_line { |line| stderr.puts("#{server}: refusing to start: #{line.chomp}") }
        exit(EXIT_STATUS)
      end

      def self.setting_problems(env)
        known = [TOOLS_VARIABLE, DOMAINS_VARIABLE, COMMANDS_VARIABLE]
        problems = (env.keys.select { |name| name.start_with?(ENV_PREFIX) } - known).map do |name|
          "environment #{name} is not accepted; the door takes only #{known.join(', ')}"
        end
        problems + mode_problems(env[TOOLS_VARIABLE], env[DOMAINS_VARIABLE], env[COMMANDS_VARIABLE])
      end

      def self.mode_problems(tools, domains, commands)
        return stray_problems(domains, commands) if tools.nil?
        unless MODES.include?(tools)
          return ["#{TOOLS_VARIABLE}=#{tools.inspect} is not accepted; the values are #{MODES.map(&:inspect).join(' and ')}"]
        end

        problems = []
        if split_paths(domains.to_s).empty?
          problems << "#{TOOLS_VARIABLE}=#{tools} needs #{DOMAINS_VARIABLE}, the domains this door may read"
        end
        problems + command_problems(tools, commands)
      end

      def self.stray_problems(domains, commands)
        stray = { DOMAINS_VARIABLE => domains, COMMANDS_VARIABLE => commands }.compact.keys
        return [] if stray.empty?

        ["#{stray.join(' and ')} set without #{TOOLS_VARIABLE}=#{READERS} or #{TOOLS_VARIABLE}=#{COMMANDS}; " \
         "they only narrow a restricted door"]
      end

      def self.command_problems(tools, commands)
        if tools == COMMANDS && split_names(commands).empty?
          ["#{TOOLS_VARIABLE}=#{COMMANDS} needs #{COMMANDS_VARIABLE}, the commands this door may dispatch"]
        elsif tools == READERS && !commands.nil?
          ["#{COMMANDS_VARIABLE} is set in reader mode; it only narrows a commands door"]
        else
          []
        end
      end

      def self.split_paths(value) = value.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)

      def self.split_names(value) = value.to_s.split(",").map(&:strip).reject(&:empty?).uniq

      # The named domains, resolved against Storehouse::BOOT_ROOT; nil when unrestricted.
      attr_reader :allowed_domains

      # The command names a commands door dispatches, as the spawner wrote them; nil unless
      # the door runs in commands mode.
      attr_reader :allowed_commands

      def initialize(allowed_domains:, allowed_commands: nil)
        @allowed_domains = allowed_domains&.map { |path| Storehouse.confine!(path, DOMAINS_VARIABLE) }.freeze
        @allowed_commands = allowed_commands&.dup&.freeze
      end

      def restricted?
        !@allowed_domains.nil?
      end

      def commands_mode?
        !@allowed_commands.nil?
      end

      def served_tools
        commands_mode? ? COMMAND_TOOLS : READER_TOOLS
      end

      def permits_tool?(name)
        !restricted? || served_tools.include?(name)
      end

      def refusal(name)
        { ok:    false,
          error: "#{name.inspect} is refused: this door runs in #{mode_label}, " \
                 "which serves only #{served_tools.join(', ')}" }
      end

      # Checked before anything boots, so a path outside the allowed set never reaches Kernel.load.
      def admit_domain!(domain)
        return domain unless restricted?
        return domain if @allowed_domains.include?(Storehouse.confine!(domain, "domain"))

        raise Runtime::TypeMismatch,
              "domain: #{domain.inspect} is refused: this door runs in #{mode_label} " \
              "and reads only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}"
      end

      # A commands door dispatches only the commands it was given. A requested name and each
      # allowed name resolve through the alias map `dispatch` uses, and the resolved verbs are
      # compared, so `complete` cannot reach a command of another aggregate that shares its short
      # name, and an allowed name that resolves to nothing admits nothing.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param command [String, nil] the command name the caller asked for
      # @raise [Runtime::TypeMismatch] when the command is not on the list
      def admit_command!(runtime, command)
        return unless commands_mode?

        verbs = Storehouse.verbs_for(runtime, [command, *allowed_commands])
        return if verbs.first && verbs.drop(1).include?(verbs.first)

        raise Runtime::TypeMismatch,
              "command: #{command.to_s.inspect} is refused: this door runs in #{mode_label} " \
              "and dispatches only #{COMMANDS_VARIABLE}: #{allowed_commands.join(', ')}"
      end

      # Every step of a batch is admitted before any step runs.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param steps [Array<Hash>] the batch, each `{"command" => ..., "args" => ...}`
      # @raise [Runtime::TypeMismatch] when any step's command is not on the list
      def admit_steps!(runtime, steps)
        Array(steps).each { |step| admit_command!(runtime, step.is_a?(Hash) ? step["command"] : nil) }
      end

      # The tool as `tools/list` shows it: on a commands door, `dispatch` names the commands it
      # serves, so a caller sees them as an enum instead of finding out by being refused.
      #
      # @param tool [Hash] a tool definition from `McpDoor::TOOLS`
      # @return [Hash] the definition, narrowed for this door
      def present(tool)
        return tool unless commands_mode? && tool[:name] == "dispatch"

        properties = tool[:inputSchema][:properties]
        narrowed = properties.merge(command: with_enum(properties[:command]),
                                    steps:   properties[:steps].merge(items: step_items(properties[:steps][:items])))
        tool.merge(description: "#{tool[:description]} This door dispatches only: #{allowed_commands.join(', ')}.",
                   inputSchema: tool[:inputSchema].merge(properties: narrowed))
      end

      def notes
        return [] unless restricted?

        commands_mode? ? commands_notes : reader_notes
      end

      private

      def with_enum(property)
        property.merge(enum: allowed_commands)
      end

      def step_items(items)
        items.merge(properties: items[:properties].merge(command: with_enum(items[:properties][:command])))
      end

      def mode_label
        commands_mode? ? "commands mode (#{TOOLS_VARIABLE}=#{COMMANDS})" : "reader mode (#{TOOLS_VARIABLE}=#{READERS})"
      end

      def reader_notes
        ["Reader mode (#{TOOLS_VARIABLE}=#{READERS}): serves #{READER_TOOLS.join(', ')}; " \
         "refuses dispatch (with dry_run and steps), behaviors and every other tool.",
         "domain: boots only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}.",
         "Reader mode limits reach and identifies no one; it is not authentication."]
      end

      def commands_notes
        ["Commands mode (#{TOOLS_VARIABLE}=#{COMMANDS}): serves #{READER_TOOLS.join(', ')} and dispatch of only " \
         "#{COMMANDS_VARIABLE}: #{@allowed_commands.join(', ')}; refuses behaviors and every other tool.",
         "domain: boots only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}.",
         "Commands mode limits reach and identifies no one; role: stays self-asserted and it is not authentication."]
      end
    end
  end
end
