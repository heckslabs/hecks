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

      # The variables every confined agent sees besides the ones its profile names.
      BASE_ENV = %w[PATH HOME LANG LC_ALL TERM TMPDIR].freeze

      # Home-relative places an agent may not read: credentials and the harness's own state.
      CREDENTIAL_PATHS = %w[
        .ssh .aws .gnupg .claude .config/gh .config/op .gem/credentials .netrc Library/Keychains
      ].freeze

      SANDBOX = "/usr/bin/sandbox-exec"

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

      # @param tools [Array<String>] the tools the agent is given
      # @param writable [Array<String>] directories the agent may write
      # @param network [Symbol] one of `NETWORKS`
      # @param env [Array<String>] environment variable names to pass through
      # @param timeout [Integer, nil] seconds the run may take
      # @param budget [Float, nil] dollars the run may spend
      # @raise [ArgumentError] when `network` is not one of `NETWORKS`
      def initialize(tools: [], writable: [], network: :none, env: [], timeout: nil, budget: nil)
        unless NETWORKS.include?(network)
          raise ArgumentError, "network must be one of #{NETWORKS.inspect}, not #{network.inspect}"
        end

        @tools = tools.dup.freeze
        @writable = writable.dup.freeze
        @network = network
        @env = env.dup.freeze
        @timeout = timeout
        @budget = budget
      end

      # @return [Boolean] whether this machine can confine a process
      def available?
        File.executable?(SANDBOX)
      end

      # @param words [Array<String>] the agent's command
      # @return [Array<String>] `words`, run under the sandbox with this profile's policy
      def confine(words)
        [SANDBOX, "-p", policy, *words]
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
        flags = tools.empty? ? [] : ["--tools", tools.join(","), "--allowedTools", tools.join(",")]
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

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def quote(path)
        %("#{path.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
      end
    end
  end
end
