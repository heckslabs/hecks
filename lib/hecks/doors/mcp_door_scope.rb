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
        npm_only output path payload payload_file port rust_binary scheme stage_dir state_path stdio url
        write
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
        problems = EnvProblems.setting_problems(env)
        raise ArgumentError, problems.join("\n") unless problems.empty?
        return new(allowed_domains: nil) unless env[TOOLS_VARIABLE]

        commands = env[TOOLS_VARIABLE] == COMMANDS ? EnvProblems.split_names(env[COMMANDS_VARIABLE]) : nil
        new(allowed_domains: EnvProblems.split_paths(env[DOMAINS_VARIABLE]), allowed_commands: commands)
      end

      # Refuses to stderr, not stdout, which carries the MCP protocol.
      def self.start!(server:, env: ENV, stderr: $stderr)
        from_env(env)
      rescue ArgumentError, Runtime::TypeMismatch => e
        e.message.each_line { |line| stderr.puts("#{server}: refusing to start: #{line.chomp}") }
        exit(EXIT_STATUS)
      end

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
                 "which serves only #{served_tools.join(", ")}" }
      end

      # Checked before anything boots, so a path outside the allowed set never reaches Kernel.load.
      def admit_domain!(domain)
        return domain unless restricted?
        return domain if @allowed_domains.include?(Storehouse.confine!(domain, "domain"))

        raise Runtime::TypeMismatch,
              "domain: #{domain.inspect} is refused: this door runs in #{mode_label} " \
              "and reads only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(", ")}"
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
                "and dispatches only #{COMMANDS_VARIABLE}: #{allowed_commands.join(", ")}"
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

        ArgumentPolicy.admit!(args, mode_label)
      end

      # The one domain a restricted door serves, when it serves exactly one: a call may leave
      # `domain:` out and get it. Nil for an unrestricted door and for one that names several.
      #
      # @return [String, nil] the domain path as `HECKS_DOOR_DOMAINS` named it, resolved
      def default_domain
        @allowed_domains.first if restricted? && @allowed_domains.size == 1
      end

      # The arguments with the default domain filled in when the caller left it out.
      #
      # @param args [Hash] a tool call's arguments
      # @return [Hash] `args`, with `"domain"` set when the door has a default and none was given
      def with_default_domain(args)
        return args unless default_domain && args["domain"].to_s.strip.empty?

        args.merge("domain" => default_domain)
      end

      # The tool as `tools/list` shows it; see `Presenter.present`.
      #
      # @param tool [Hash] a tool definition from `McpDoor::TOOLS`
      # @param guide [Array<String>, nil] one line per allowed command (`Storehouse.command_guide`)
      # @return [Hash] the definition, narrowed for this door
      def present(tool, guide = nil)
        Presenter.present(self, tool, guide)
      end

      def notes
        return [] unless restricted?

        commands_mode? ? Presenter.commands_notes(@allowed_domains, @allowed_commands) : Presenter.reader_notes(@allowed_domains)
      end

      private

      def mode_label
        commands_mode? ? "commands mode (#{TOOLS_VARIABLE}=#{COMMANDS})" : "reader mode (#{TOOLS_VARIABLE}=#{READERS})"
      end
    end
  end
end

require_relative "mcp_door_scope/env_problems"
require_relative "mcp_door_scope/argument_policy"
require_relative "mcp_door_scope/presenter"
