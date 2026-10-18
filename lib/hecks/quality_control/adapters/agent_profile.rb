# frozen_string_literal: true

module Hecks
  module Adapters
    # What one `Agent` run may do: which tools it holds, where it may write, which environment
    # variables it sees and how long it may run.
    #
    # Confinement is the permission rules of the `claude` command itself, so a run keeps the
    # user's own login. Only the default `claude` command understands them; `Agent` refuses to
    # run any other command under a profile.
    class AgentProfile
      # The variables every confined agent sees besides the ones its profile names.
      BASE_ENV = %w[PATH HOME USER LOGNAME SHELL LANG LC_ALL TERM TMPDIR].freeze

      # The tools that write files; a confined run holds them only through path rules.
      WRITING_TOOLS = %w[Write Edit MultiEdit NotebookEdit].freeze

      # @return [Array<String>] the tools the agent is given
      attr_reader :tools
      # @return [Array<String>] the directories the agent may write
      attr_reader :writable
      # @return [Array<String>] the environment variable names the agent may see besides `BASE_ENV`
      attr_reader :env
      # @return [Integer, nil] seconds the run may take; nil for no limit
      attr_reader :timeout
      # @return [Float, nil] the most the run may spend, in dollars, for an agent that takes one
      attr_reader :budget

      # @param tools [Array<String>] the tools the agent is given
      # @param writable [Array<String>] directories the agent may write
      # @param env [Array<String>] environment variable names to pass through
      # @param timeout [Integer, nil] seconds the run may take
      # @param budget [Float, nil] dollars it may spend
      def initialize(tools: [], writable: [], env: [], timeout: nil, budget: nil)
        @tools = tools.dup.freeze
        @writable = writable.dup.freeze
        @env = env.dup.freeze
        @timeout = timeout
        @budget = budget
      end

      # @return [String] the `claude` permission mode this profile runs under
      def permission_mode
        "dontAsk"
      end

      # @param source [Hash{String => String}] the environment to take values from
      # @return [Hash{String => String}] only the variables this profile lets the agent see
      def environment(source = ENV)
        source.to_h.slice(*BASE_ENV, *env)
      end

      # The `claude` flags this profile's tools and budget become. The writing tools are held only
      # through an `Edit` rule per writable directory, which every file-writing tool answers to.
      #
      # @return [Array<String>]
      def tool_flags
        flags = tools.empty? ? [] : ["--tools", tools.join(","), "--allowedTools", *allowed_tools]
        flags += ["--strict-mcp-config"]
        flags + (budget ? ["--max-budget-usd", budget.to_s] : [])
      end

      private

      def allowed_tools
        tools - WRITING_TOOLS + writable.map { |path| "Edit(/#{real(path)}/**)" }
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
    end
  end
end
