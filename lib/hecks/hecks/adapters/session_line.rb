# frozen_string_literal: true

require "json"
require_relative "architect_verdict"
require_relative "session_hooks"
require_relative "credential_scrub"
require_relative "mcp_selection"
require_relative "run_role"

module Hecks
  module Adapters
    # The command line that starts one background session: the `claude` command, the agent it runs
    # as (the run's {RunRole}, so a fill-started coder loads `coder.md` and its model), and the
    # brief after a `--` so it is never taken for a flag. An argument list, never a string for a
    # shell. Its settings disable each project MCP server the role file's tools do not
    # name ({McpSelection}), so a coder starts none; `--strict-mcp-config` is not used, since it
    # would drop the role's own frontmatter servers. A role's `hecks-mcp` server narrows itself from
    # the `CLAUDE_CODE_AGENT` variable Claude Code gives it (see `Driving::Mcp::Roles`); a resume
    # names the same role with `--agent` and carries the same settings (see {ClaudeResumption}).
    class SessionLine
      # @param command [String] the command that starts sessions
      # @param nice [Array<String>] the niceness prefix, empty for none
      # @param hooks [SessionHooks] says the hooks a run's session carries
      # @param credentials [#scrub?] says whether a role's session starts without credentials
      #   ({Dispatching::CredentialSetting}); none is scrubbed by default
      def initialize(command:, nice:, hooks: SessionHooks.new(launcher: nil), credentials: KEPT)
        @command = command
        @nice = nice
        @hooks = hooks
        @credentials = credentials
      end

      # Keeps every session's credentials.
      KEPT = Object.new.tap { |kept| kept.define_singleton_method(:scrub?) { |_agent| false } }.freeze

      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, and `agent` when named
      # @param environment [Hash{String => String}] what the session's own commands should see
      # @return [Array<String>] the argument list
      def arguments(held, environment = {})
        agent = RunRole.of(held)
        [*@nice, @command, *(agent ? ["--agent", agent] : []), *settings(environment, held, agent), "--bg",
         "--", briefed(plain(held[:brief]), agent)]
      end

      private

      # A background session does not take the environment of the process that starts it, so the
      # variables its commands read (today the caller name) go in the settings `env` block, which
      # Claude Code applies to every command the session runs. The `hooks` block makes the session
      # announce its own end (see {SessionHooks}). A role the world scrubs also carries
      # {CredentialScrub}'s variables and deny rules, and every block names the project MCP servers
      # the role does not start ({McpSelection}).
      # @return [Array<String>] the `--settings` flag and its JSON, or nothing for no env or hooks
      def settings(environment, held, agent)
        block = { "env" => environment, "hooks" => @hooks.for(plain(held[:run])) }
                .merge(McpSelection.settings(plain(held[:repo]), agent))
        block = scrubbed(block, agent).reject { |_, value| value.empty? }
        block.empty? ? [] : ["--settings", JSON.generate(block)]
      end

      def scrubbed(block, agent) = @credentials.scrub?(agent) ? CredentialScrub.onto(block) : block

      # @return [String] the brief, with the verdict format added for the architect
      def briefed(brief, agent) = agent == "architect" ? "#{brief}#{ArchitectVerdict::REQUEST}" : brief.to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
