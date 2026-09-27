require_relative "runtime/errors"

module Hecks
  # What one spawned `bin/hecks_mcp_door` may do: every tool against any domain under
  # `Storehouse::BOOT_ROOT` (the default), or, in reader mode, only the reader tools
  # against the domains its spawner named. ADR 0072, decision 2.
  #
  # ## Reach, not identity
  #
  # This is a capability allowlist, not authentication. It identifies no one and adds no
  # secret: whoever can spawn the door chooses its mode, and whoever can write to its stdin
  # gets whatever that mode allows. What it buys is a smaller surface per agent. A reader
  # door cannot dispatch, cannot run `.behaviors` files, and cannot `Kernel.load` Ruby from
  # a domain its spawner did not name.
  #
  # ## Why `HECKS_DOOR_*` and not `HECKS_MCP_*`
  #
  # `McpStdioGuard` refuses every `HECKS_MCP_*` variable except
  # `HECKS_MCP_TRANSPORT=stdio`, and every argument except `--stdio`, so that no option can
  # ask a server for another transport. Those refusals belong to ADR 0062. The settings
  # here live under their own prefix so the guard stays exactly as that ADR describes it,
  # and an unknown `HECKS_DOOR_*` name is refused here, the same fail-closed way.
  #
  # ## The settings
  #
  # - `HECKS_DOOR_TOOLS=readers` turns reader mode on. Unset means every tool, as before.
  #   Any other value refuses to start.
  # - `HECKS_DOOR_DOMAINS` lists the domains a reader door may name, separated by
  #   `File::PATH_SEPARATOR` (`:` on Unix), each resolved against `Storehouse::BOOT_ROOT`.
  #   Required in reader mode and refused without it.
  #
  # ## The allowed set is named, not loaded
  #
  # The door boots a domain afresh on every call and keeps nothing loaded between calls,
  # so there is no set of already-loaded domains to check against. The allowed set is the
  # list the spawner named, resolved to absolute paths at startup. A call's `domain:` is
  # resolved the same way and compared before anything boots, so a path outside the set
  # never reaches `Kernel.load`. The comparison is on resolved path text: a symlink under a
  # named path is followed when that domain boots, as it is for every domain today.
  class McpDoorScope
    ENV_PREFIX       = "HECKS_DOOR_".freeze
    TOOLS_VARIABLE   = "HECKS_DOOR_TOOLS".freeze
    DOMAINS_VARIABLE = "HECKS_DOOR_DOMAINS".freeze
    READERS          = "readers".freeze
    EXIT_STATUS      = 2

    # The tools a reader door serves. Each reads a domain or the door's own audit log and
    # writes no domain state. `query` and `state` still append their call to that audit
    # log. `validate` boots the domain it is given, so it is held to the allowed set like
    # every other domain-scoped tool. `domains` lists directories and loads nothing.
    READER_TOOLS = %w[query events state catalog describe validate domains history follow].freeze

    # Reads the door's mode from its environment.
    #
    # @param env [Hash{String => String}] the process environment
    # @return [McpDoorScope] an unrestricted scope when no `HECKS_DOOR_*` variable is set;
    #   otherwise a reader scope over the named domains
    # @raise [ArgumentError] with every problem found, one per line, when the settings are
    #   not a mode this door knows
    # @raise [Runtime::TypeMismatch] if a named domain resolves outside
    #   `Storehouse::BOOT_ROOT`
    def self.from_env(env = ENV)
      problems = setting_problems(env)
      raise ArgumentError, problems.join("\n") unless problems.empty?
      return new(allowed_domains: nil) unless env[TOOLS_VARIABLE]

      new(allowed_domains: env[DOMAINS_VARIABLE].split(File::PATH_SEPARATOR).reject(&:empty?))
    end

    # Reads the door's mode, or refuses to start on settings it does not know.
    #
    # Everything goes to `stderr`, because stdout carries the MCP protocol.
    #
    # @param server [String] the server's name, used as the line prefix
    # @param env [Hash{String => String}] the process environment
    # @param stderr [IO] where a refusal is written
    # @return [McpDoorScope] the door's scope
    # @raise [SystemExit] with status `EXIT_STATUS` when `from_env` refuses the settings
    def self.start!(server:, env: ENV, stderr: $stderr)
      from_env(env)
    rescue ArgumentError, Runtime::TypeMismatch => e
      e.message.each_line { |line| stderr.puts("#{server}: refusing to start: #{line.chomp}") }
      exit(EXIT_STATUS)
    end

    # @api private
    def self.setting_problems(env)
      unknown = env.keys.select { |name| name.start_with?(ENV_PREFIX) } - [TOOLS_VARIABLE, DOMAINS_VARIABLE]
      problems = unknown.map do |name|
        "environment #{name} is not accepted; the door takes only #{TOOLS_VARIABLE} and #{DOMAINS_VARIABLE}"
      end
      problems + mode_problems(env[TOOLS_VARIABLE], env[DOMAINS_VARIABLE])
    end

    # @api private
    def self.mode_problems(tools, domains)
      if tools.nil?
        domains.nil? ? [] : ["#{DOMAINS_VARIABLE} is set without #{TOOLS_VARIABLE}=#{READERS}; it only narrows a reader door"]
      elsif tools != READERS
        ["#{TOOLS_VARIABLE}=#{tools.inspect} is not accepted; the only value is #{READERS.inspect}"]
      elsif domains.to_s.split(File::PATH_SEPARATOR).none? { |path| !path.empty? }
        ["#{TOOLS_VARIABLE}=#{READERS} needs #{DOMAINS_VARIABLE}, the domains this door may read"]
      else
        []
      end
    end

    # The named domains, resolved against `Storehouse::BOOT_ROOT`; nil when unrestricted.
    #
    # @return [Array<String>, nil]
    attr_reader :allowed_domains

    # @param allowed_domains [Array<String>, nil] the domains a reader door may name, as
    #   given; nil for an unrestricted door
    # @raise [Runtime::TypeMismatch] if a named domain resolves outside `Storehouse::BOOT_ROOT`
    def initialize(allowed_domains:)
      @allowed_domains = allowed_domains&.map { |path| Storehouse.confine!(path, DOMAINS_VARIABLE) }.freeze
    end

    # Tells whether this door runs in reader mode.
    #
    # @return [Boolean] true when the spawner set `HECKS_DOOR_TOOLS=readers`
    def restricted?
      !@allowed_domains.nil?
    end

    # Tells whether this door serves a tool.
    #
    # @param name [String] the tool name from a `tools/call` request
    # @return [Boolean] true for every name on an unrestricted door; on a reader door, true
    #   only for `READER_TOOLS`
    def permits_tool?(name)
      !restricted? || READER_TOOLS.include?(name)
    end

    # Builds the answer to a call for a tool this door does not serve.
    #
    # @param name [String] the tool name from a `tools/call` request
    # @return [Hash{Symbol => Object}] `{ok: false, error:}`, the error naming the mode and
    #   the tools it serves
    def refusal(name)
      { ok:    false,
        error: "#{name.inspect} is refused: this door runs in reader mode (#{TOOLS_VARIABLE}=#{READERS}), " \
               "which serves only #{READER_TOOLS.join(', ')}" }
    end

    # Checks a call's `domain:` against the allowed set, before anything boots.
    #
    # @param domain [String, nil] the caller's `domain:` argument
    # @return [String, nil] `domain` unchanged, so an unrestricted door boots exactly what
    #   it did before
    # @raise [Runtime::TypeMismatch] on a reader door, if `domain` resolves outside
    #   `Storehouse::BOOT_ROOT` or to a path its spawner did not name
    def admit_domain!(domain)
      return domain unless restricted?
      return domain if @allowed_domains.include?(Storehouse.confine!(domain, "domain"))

      raise Runtime::TypeMismatch,
            "domain: #{domain.inspect} is refused: this door runs in reader mode (#{TOOLS_VARIABLE}=#{READERS}) " \
            "and reads only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}"
    end

    # The startup warning lines that describe this door's mode.
    #
    # @return [Array<String>] empty when unrestricted; on a reader door, what it serves,
    #   what it refuses, the domains it reads, and that it identifies no one
    def notes
      return [] unless restricted?

      ["Reader mode (#{TOOLS_VARIABLE}=#{READERS}): serves #{READER_TOOLS.join(', ')}; " \
       "refuses dispatch (with dry_run and steps), behaviors and every other tool.",
       "domain: boots only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}.",
       "Reader mode limits reach and identifies no one; it is not authentication."]
    end
  end
end
