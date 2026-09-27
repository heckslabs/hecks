require_relative "runtime/errors"

module Hecks
  # What a spawned bin/hecks_mcp_door may do: every tool by default, or only
  # reader tools against named domains in reader mode — reach, not identity (ADR 0072).
  class McpDoorScope
    ENV_PREFIX       = "HECKS_DOOR_".freeze
    TOOLS_VARIABLE   = "HECKS_DOOR_TOOLS".freeze
    DOMAINS_VARIABLE = "HECKS_DOOR_DOMAINS".freeze
    READERS          = "readers".freeze
    EXIT_STATUS      = 2

    # The tools a reader door serves — each reads a domain or the door's own
    # audit log and writes no domain state. `validate` still boots its
    # domain, so it stays bound to the allowed set like every other tool.
    READER_TOOLS = %w[query events state catalog describe validate domains history follow].freeze

    # Unrestricted when no HECKS_DOOR_* variable is set.
    def self.from_env(env = ENV)
      problems = setting_problems(env)
      raise ArgumentError, problems.join("\n") unless problems.empty?
      return new(allowed_domains: nil) unless env[TOOLS_VARIABLE]

      new(allowed_domains: env[DOMAINS_VARIABLE].split(File::PATH_SEPARATOR).reject(&:empty?))
    end

    # Refuses to stderr, not stdout, which carries the MCP protocol.
    def self.start!(server:, env: ENV, stderr: $stderr)
      from_env(env)
    rescue ArgumentError, Runtime::TypeMismatch => e
      e.message.each_line { |line| stderr.puts("#{server}: refusing to start: #{line.chomp}") }
      exit(EXIT_STATUS)
    end

    def self.setting_problems(env)
      unknown = env.keys.select { |name| name.start_with?(ENV_PREFIX) } - [TOOLS_VARIABLE, DOMAINS_VARIABLE]
      problems = unknown.map do |name|
        "environment #{name} is not accepted; the door takes only #{TOOLS_VARIABLE} and #{DOMAINS_VARIABLE}"
      end
      problems + mode_problems(env[TOOLS_VARIABLE], env[DOMAINS_VARIABLE])
    end

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

    # The named domains, resolved against Storehouse::BOOT_ROOT; nil when unrestricted.
    attr_reader :allowed_domains

    def initialize(allowed_domains:)
      @allowed_domains = allowed_domains&.map { |path| Storehouse.confine!(path, DOMAINS_VARIABLE) }.freeze
    end

    def restricted?
      !@allowed_domains.nil?
    end

    def permits_tool?(name)
      !restricted? || READER_TOOLS.include?(name)
    end

    def refusal(name)
      { ok:    false,
        error: "#{name.inspect} is refused: this door runs in reader mode (#{TOOLS_VARIABLE}=#{READERS}), " \
               "which serves only #{READER_TOOLS.join(', ')}" }
    end

    # Checked before anything boots, so a path outside the allowed set never reaches Kernel.load.
    def admit_domain!(domain)
      return domain unless restricted?
      return domain if @allowed_domains.include?(Storehouse.confine!(domain, "domain"))

      raise Runtime::TypeMismatch,
            "domain: #{domain.inspect} is refused: this door runs in reader mode (#{TOOLS_VARIABLE}=#{READERS}) " \
            "and reads only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}"
    end

    def notes
      return [] unless restricted?

      ["Reader mode (#{TOOLS_VARIABLE}=#{READERS}): serves #{READER_TOOLS.join(', ')}; " \
       "refuses dispatch (with dry_run and steps), behaviors and every other tool.",
       "domain: boots only #{DOMAINS_VARIABLE}: #{@allowed_domains.join(', ')}.",
       "Reader mode limits reach and identifies no one; it is not authentication."]
    end
  end
end
