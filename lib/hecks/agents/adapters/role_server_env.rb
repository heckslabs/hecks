# frozen_string_literal: true

require "hecks/naming"
require "hecks/adapters/driving/mcp_scope"

module Hecks
  module Adapters
    # The `HECKS_SERVER_*` variables that start a role's MCP server restricted to the commands its
    # routing rows name. A pattern is `Aggregate.verb` or `Aggregate.*`; it counts when the domain
    # the server serves has a command of that name. A pattern that names a question, another
    # bluebook's command or a shell command (`git status`) adds nothing.
    #
    # A role with no rows, or none that names a command, gets no variables, so its server stays as
    # unrestricted as the role's own session is.
    class RoleServerEnv
      McpScope = Driving::McpScope
      private_constant :McpScope

      # The domain a role's server serves, relative to the checkout it is started in.
      DOMAIN = "lib/hecks/hecks"

      # What `Aggregate.verb` or `Aggregate.*` looks like.
      PATTERN = /\A(?<aggregate>[A-Za-z_]\w*)\.(?<verb>\*|\w+[!?]?)\z/

      # @param patterns [Array<String>] the role's `RoutingRule` patterns
      # @param names [#call] answers the command names the served domain has, as a person types
      #   them (`dispatch.fill`)
      def initialize(patterns:, names:)
        @patterns = patterns
        @names = names
      end

      # @return [Hash{String => String}] the three variables, or empty when no command is named
      def variables
        commands = expanded
        return {} if commands.empty?

        { McpScope::TOOLS_VARIABLE => McpScope::COMMANDS, McpScope::DOMAINS_VARIABLE => DOMAIN,
          McpScope::COMMANDS_VARIABLE => commands.join(",") }
      end

      # @return [Array<String>] the served domain's command names the patterns name, sorted
      def expanded
        available = @names.call
        @patterns.flat_map { |pattern| matching(pattern, available) }.uniq.sort
      end

      private

      def matching(pattern, available)
        found = PATTERN.match(pattern)
        return [] unless found

        prefix = "#{Naming.snake(found[:aggregate])}."
        return available.select { |name| name.start_with?(prefix) } if found[:verb] == "*"

        name = "#{prefix}#{Naming.snake(found[:verb].delete_suffix("!").delete_suffix("?"))}"
        available.include?(name) ? [name] : []
      end
    end
  end
end
