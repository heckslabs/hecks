# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # The project MCP servers a role's session does not start: each server `.mcp.json` names that
    # the role file's `tools:` line does not name as `mcp__<server>` (or one of its tools,
    # `mcp__<server>__<tool>`). It compares the two declared lists and decides nothing else.
    #
    # A session with no role, a role with no file, a file with no `tools:` line or with `*`, and a
    # checkout whose `.mcp.json` cannot be read disable nothing. A role's own frontmatter servers
    # (`mcpServers:`) are not project servers, so they are never disabled. The answer goes in the
    # session's `--settings` as `disabledMcpjsonServers`, on its start and on each resume, since a
    # resume does not keep the start's settings.
    class McpSelection
      # The settings key that keeps a project server from starting.
      KEY = "disabledMcpjsonServers"

      # A role file's frontmatter: what lies between its two leading `---` lines.
      FRONTMATTER = /\A---\n(.*?)\n---/m

      # The frontmatter's `tools:` line, and the comma-separated tools it names.
      TOOLS_LINE = /^tools:[ \t]*(.*)$/

      # @param checkout [String, nil] the run's directory, holding `.mcp.json` and `.claude/agents`
      # @param agent [String, nil] the role the session runs as
      # @return [Hash{String => Array<String>}] the settings entry, or empty when none is disabled
      def self.settings(checkout, agent)
        names = new(checkout.to_s, agent.to_s).disabled
        names.empty? ? {} : { KEY => names }
      end

      # @param checkout [String] the run's directory
      # @param agent [String] the role, empty for none
      def initialize(checkout, agent)
        @checkout = checkout
        @agent = agent
      end

      # @return [Array<String>] the project servers the role's tools do not name
      def disabled
        tools = role_tools
        return [] if tools.nil? || tools.include?("*")

        servers.reject { |server| tools.any? { |tool| tool == "mcp__#{server}" || tool.start_with?("mcp__#{server}__") } }
      end

      private

      # @return [Array<String>] the server names in `.mcp.json`, none when it cannot be read
      def servers
        JSON.parse(File.read(File.join(@checkout, ".mcp.json"))).fetch("mcpServers", {}).keys
      rescue SystemCallError, JSON::ParserError, NoMethodError
        []
      end

      # @return [Array<String>, nil] the role file's tools, nil when it names no limit
      def role_tools
        return nil if @agent.empty? || @checkout.empty?

        line = frontmatter[TOOLS_LINE, 1]
        line&.split(",")&.map(&:strip)
      end

      # @return [String] the role file's frontmatter, empty when there is no readable one
      def frontmatter
        File.read(File.join(@checkout, ".claude", "agents", "#{@agent}.md"))[FRONTMATTER, 1].to_s
      rescue SystemCallError
        ""
      end
    end
  end
end
