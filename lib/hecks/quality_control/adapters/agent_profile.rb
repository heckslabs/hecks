# frozen_string_literal: true

require "tmpdir"

module Hecks
  module Adapters
    # What one `Agent` run may do: which tools it holds, where it may write, what it may reach on
    # the network, which environment variables it sees and how long it may run.
    #
    # Confinement uses the macOS sandbox. Where there is none, a confined run refuses to start
    # rather than run unconfined.
    class AgentProfile
      # What the network rule lets through: nothing, outbound HTTPS and name lookups, or anything.
      NETWORKS = %i[none https any].freeze

      # How a run is confined: under the operating system's sandbox, or by the permission rules
      # of the `claude` command itself. Only the second leaves the user's own login usable, since
      # the sandbox refuses the keychain and `~/.claude`.
      CONFINEMENTS = %i[sandbox permissions].freeze

      # The variables every confined agent sees besides the ones its profile names.
      BASE_ENV = %w[PATH HOME USER LOGNAME SHELL LANG LC_ALL TERM TMPDIR].freeze

      # The tools that write files; a permissions-confined run holds them only through path rules.
      WRITING_TOOLS = %w[Write Edit MultiEdit NotebookEdit].freeze

      # Home-relative places an agent may not read: credentials and the harness's own state.
      CREDENTIAL_PATHS = %w[
        .ssh .aws .gnupg .claude .config/gh .config/op .gem/credentials .netrc Library/Keychains
      ].freeze

      SANDBOX = "/usr/bin/sandbox-exec"

      # The keywords `new` takes besides the four lists, with what each defaults to.
      LIMIT_DEFAULTS = { timeout: nil, budget: nil, confinement: :sandbox }.freeze

      # @return [Array<String>] the tools the agent is given
      attr_reader :tools
      # @return [Array<String>] the directories the agent may write, besides the temp directory
      attr_reader :writable
      # @return [Symbol] one of `NETWORKS`
      attr_reader :network
      # @return [Array<String>] the environment variable names the agent may see besides `BASE_ENV`
      attr_reader :env
      # @return [Integer, nil] seconds the run may take; nil for no limit
      attr_reader :timeout
      # @return [Float, nil] the most the run may spend, in dollars, for an agent that takes one
      attr_reader :budget
      # @return [Symbol] one of `CONFINEMENTS`
      attr_reader :confinement

      # @param tools [Array<String>] the tools the agent is given
      # @param writable [Array<String>] directories the agent may write
      # @param network [Symbol] one of `NETWORKS`
      # @param env [Array<String>] environment variable names to pass through
      # @param limits [Hash] `timeout:` (Integer, nil) seconds the run may take, `budget:`
      #   (Float, nil) dollars it may spend, `confinement:` one of `CONFINEMENTS` (`network`
      #   applies to the sandbox only)
      # @raise [ArgumentError] when `network` or `confinement` is not one it knows
      def initialize(tools: [], writable: [], network: :none, env: [], **limits)
        limits = LIMIT_DEFAULTS.merge(reject_unknown(limits))
        ensure_known(:network, NETWORKS, network)
        ensure_known(:confinement, CONFINEMENTS, limits[:confinement])
        @tools = tools.dup.freeze
        @writable = writable.dup.freeze
        @network = network
        @env = env.dup.freeze
        @timeout, @budget, @confinement = limits.values_at(:timeout, :budget, :confinement)
      end

      # @return [Boolean] whether this profile is enforced by the operating system's sandbox
      def sandboxed?
        confinement == :sandbox
      end

      # @return [Boolean] whether this machine can apply this profile's confinement
      def available?
        !sandboxed? || File.executable?(SANDBOX)
      end

      # @param words [Array<String>] the agent's command
      # @return [Array<String>] `words`, run under the sandbox with this profile's policy; the
      #   words unchanged when the confinement is the command's own permission rules
      def confine(words)
        sandboxed? ? [SANDBOX, "-p", policy, *words] : words
      end

      # @return [String] the `claude` permission mode this profile runs under
      def permission_mode
        sandboxed? ? "acceptEdits" : "dontAsk"
      end

      # @param source [Hash{String => String}] the environment to take values from
      # @return [Hash{String => String}] only the variables this profile lets the agent see
      def environment(source = ENV)
        source.to_h.slice(*BASE_ENV, *env)
      end

      # The `claude` flags this profile's tools and budget become.
      #
      # @return [Array<String>]
      def tool_flags
        flags = tools.empty? ? [] : ["--tools", tools.join(","), "--allowedTools", *allowed_tools]
        flags += ["--strict-mcp-config"] unless sandboxed?
        flags + (budget ? ["--max-budget-usd", budget.to_s] : [])
      end

      # @return [String] the sandbox policy: reads open but for credentials, writes where allowed
      def policy
        [
          "(version 1)", "(allow default)",
          "(deny file-write*)", write_rule, "(deny file-read*#{paths_clause(credential_paths)})",
          *network_rules
        ].join("\n")
      end

      private

      # The tools allowed without asking. A permissions-confined run holds the writing tools only
      # through an `Edit` rule per writable directory, which every file-writing tool answers to.
      def allowed_tools
        return [tools.join(",")] if sandboxed?

        tools - WRITING_TOOLS + writable.map { |path| "Edit(/#{real(path)}/**)" }
      end

      def write_rule
        allowed = [real(Dir.tmpdir), *writable.map { |path| real(path) }]
        devices = '(literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/")'
        "(allow file-write*#{paths_clause(allowed)} #{devices})"
      end

      def credential_paths
        CREDENTIAL_PATHS.map { |path| File.join(Dir.home, path) }
      end

      def paths_clause(paths)
        paths.map { |path| " (subpath #{quote(path)})" }.join
      end

      def network_rules
        case network
        when :any then []
        when :https then ["(deny network*)", '(allow network-outbound (remote tcp "*:443") (remote udp "*:53"))',
                          '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))']
        else ["(deny network*)"]
        end
      end

      def reject_unknown(limits)
        unknown = limits.keys - LIMIT_DEFAULTS.keys
        return limits if unknown.empty?

        raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}"
      end

      def ensure_known(name, allowed, value)
        return if allowed.include?(value)

        raise ArgumentError, "#{name} must be one of #{allowed.inspect}, not #{value.inspect}"
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def quote(path)
        %("#{path.gsub("\\", "\\\\\\\\").gsub('"', '\\"')}")
      end
    end
  end
end
