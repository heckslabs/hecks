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

      # Argument names a restricted door never passes on, whatever command carries them: each one
      # names a host or a URL, a binary to run, a place to write, a port to open, a store to
      # switch to, or flips a command from a preview to a change of state.
      DENIED_ARGUMENTS = %w[
        adapter artifact confirm expected from gem_only header health_path host no_wait npm_local
        npm_only output path payload payload_file port rust_binary scheme state_path stdio url write
      ].freeze

      # Argument names whose values are paths (a comma-separated list for some). A restricted door
      # passes them on only when each resolves, symlinks followed, inside `Storehouse::BOOT_ROOT`,
      # and holds no colon: `host:repo` and `https://host/x` would otherwise pass as relative paths.
      PATH_ARGUMENTS = %w[dir domain domains file fixture paths root script].freeze

      # Argument names whose values are git refs: plain names only, so a value cannot read as an
      # option to git.
      REF_ARGUMENTS = %w[ref].freeze

      # What a plain git ref looks like: no leading dash, no `..`, no spaces.
      PLAIN_REF = %r{\A[A-Za-z0-9][A-Za-z0-9._/~^@-]*\z}

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
      # @param args [Hash, nil] the arguments the caller gave it; see `admit_arguments!`
      # @raise [Runtime::TypeMismatch] when the command is not on the list or an argument is refused
      def admit_command!(runtime, command, args = nil)
        return unless commands_mode?

        verbs = Storehouse.verbs_for(runtime, [command, *allowed_commands])
        unless verbs.first && verbs.drop(1).include?(verbs.first)
          raise Runtime::TypeMismatch,
                "command: #{command.to_s.inspect} is refused: this door runs in #{mode_label} " \
                "and dispatches only #{COMMANDS_VARIABLE}: #{allowed_commands.join(', ')}"
        end

        admit_arguments!(args)
      end

      # Every step of a batch is admitted before any step runs.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param steps [Array<Hash>] the batch, each `{"command" => ..., "args" => ...}`
      # @raise [Runtime::TypeMismatch] when a step names a command off the list or a bad argument
      def admit_steps!(runtime, steps)
        Array(steps).each do |step|
          step = {} unless step.is_a?(Hash)
          admit_command!(runtime, step["command"], step["args"])
        end
      end

      # The arguments a restricted door is about to pass to a command or a question. A command
      # list admits commands, not values, so each argument is checked by its name: a denied name
      # is refused, a path must resolve inside the root with symlinks followed, and a git ref must
      # be a plain name. Other names pass; a domain with an argument that reaches outside its own
      # files should name it in `DENIED_ARGUMENTS` or `PATH_ARGUMENTS` (ADR 0089).
      #
      # @param args [Hash, Array, nil] the arguments as the caller gave them, nested or not
      # @raise [Runtime::TypeMismatch] on the first argument refused
      def admit_arguments!(args)
        return unless restricted?

        each_argument(args) do |name, value|
          refuse_argument!(name, "never passes it on: it names a host, a binary, an output or a change of state") if
            DENIED_ARGUMENTS.include?(name)
          admit_path!(name, value) if PATH_ARGUMENTS.include?(name)
          admit_ref!(name, value) if REF_ARGUMENTS.include?(name)
        end
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

      # Yields every argument name with its value, descending into nested objects and lists, so
      # `{"file" => {"value" => "x"}}` is checked the way `{"file" => "x"}` is.
      def each_argument(args, &visit)
        case args
        when Hash
          args.each do |name, value|
            visit.call(name.to_s, value)
            each_argument(value, &visit)
          end
        when Array
          args.each { |item| each_argument(item, &visit) }
        end
      end

      # A value written as an object of one field (`{"value" => "x"}`) is that field's value.
      def scalar(value)
        return value unless value.is_a?(Hash)

        value.fetch("value") { value.fetch(:value, value) }
      end

      def refuse_argument!(name, why)
        raise Runtime::TypeMismatch, "argument: #{name.inspect} is refused: this door runs in #{mode_label} and #{why}"
      end

      def admit_path!(name, value)
        Array(scalar(value)).flat_map { |item| item.to_s.split(",") }.reject(&:empty?).each do |path|
          next if !path.include?(":") && inside_root?(path)

          refuse_argument!(name, "passes a path only when it resolves inside #{Storehouse::BOOT_ROOT} " \
                                 "and holds no colon: #{path.inspect}")
        end
      end

      def admit_ref!(name, value)
        ref = scalar(value).to_s
        return if ref.match?(PLAIN_REF) && !ref.include?("..")

        refuse_argument!(name, "passes only a plain git ref: #{ref.inspect}")
      end

      def inside_root?(path)
        root = resolve_real(Storehouse::BOOT_ROOT)
        resolved = resolve_real(File.expand_path(path, Storehouse::BOOT_ROOT))
        resolved == root || resolved.start_with?("#{root}#{File::SEPARATOR}")
      end

      # The real path of `path`, symlinks followed: of the whole path when it exists, else of its
      # deepest existing parent with the missing names put back, so a link above a file that does
      # not exist yet still shows where the file would land.
      def resolve_real(path)
        missing = []
        current = File.expand_path(path)
        until File.exist?(current)
          parent = File.dirname(current)
          break if parent == current

          missing.unshift(File.basename(current))
          current = parent
        end
        File.join(File.realpath(current), *missing)
      end

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
