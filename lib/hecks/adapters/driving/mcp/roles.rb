require_relative "../../../role_server_cache"
require_relative "../../../text"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # How the server learns what its session's role may do. An explicit `HECKS_SERVER_*`
        # setting wins and is read as it always was. Otherwise the server reads `CLAUDE_CODE_AGENT`,
        # which Claude Code gives every server it starts, a resumed session's too, and asks
        # {RoleServerCache} what the role's routing rows name:
        #
        # - no agent, a role with no rows, or no agents bluebook: unrestricted;
        # - a role whose rows name commands: a commands server for exactly those;
        # - a role with rows and no named command, or rows that cannot be read (and why): no tool.
        #
        # A cached answer is read without the framework. When none is cached the framework loads
        # on the first call that needs the scope, works the answer out and writes it for the next
        # server.
        module Roles
          # The variable Claude Code sets to the agent a session runs as.
          AGENT_VARIABLE = "CLAUDE_CODE_AGENT".freeze

          # What {#worked_out} answers when the role's rows could not be read: the error, carried to
          # the closed scope so a broken agents bluebook is never read as a role with no commands.
          Unreadable = Struct.new(:reason)

          # Read once, so a bad setting refuses to start the server before anything is written to
          # stdout. A role scope that is not cached yet is worked out here, by the first call that
          # needs it.
          #
          # @return [McpScope]
          def scope
            @scope ||= role_scope
          end

          # The standing notes, then what this server's scope says about `domain:`. A role scope
          # still to be worked out is named, not worked out: nothing loads at startup.
          def warning_notes
            return NOTES[0, 2] + ["role #{pending_role}: its commands are read on the first call"] if pending_role

            NOTES[0, 2] + (scope.restricted? ? scope.notes : [NOTES[2]])
          end

          # @return [String, nil] the role whose answer is not cached yet and not worked out yet
          def pending_role
            role, found = agent_lookup
            role if found == RoleServerCache::MISS && @scope.nil?
          end

          private

          def base_scope = (@base_scope ||= McpScope.start!(server: Tools::Mcp::SERVER))

          # [role, what the cache holds for it], or nil when a setting or no agent decides.
          def agent_lookup
            return @agent_lookup if defined?(@agent_lookup)

            role = ENV[AGENT_VARIABLE].to_s.strip
            @agent_lookup = base_scope.restricted? || role.empty? ? nil : [role, RoleServerCache.lookup(checkout, role)]
          end

          def checkout = Storehouse::BOOT_ROOT

          def role_scope
            role, found = agent_lookup
            return base_scope unless role

            found = worked_out(role) if found == RoleServerCache::MISS
            for_role(role, found)
          end

          def for_role(role, found)
            return base_scope if found == RoleServerCache::UNRESTRICTED
            return McpScope.new(allowed_domains: [], closed_role: role).unreadable(found.reason) if found.is_a?(Unreadable)
            return McpScope.new(allowed_domains: [], closed_role: role) if found.empty?

            McpScope.new(allowed_domains: [RoleServerCache::DOMAIN], allowed_commands: found)
          end

          # Loads the framework, works out every role's commands for this checkout and writes them.
          # A checkout whose agents bluebook will not answer serves no tool, since that the role has
          # no rows cannot be shown, and the answer carries the error ({Unreadable}).
          def worked_out(role)
            framework!
            require "hecks/agents/adapters/routing_guard"
            table = RoutingGuard.new(checkout: checkout).server_table
            RoleServerCache.write(checkout, table)
            table.key?(role) ? table.fetch(role) : RoleServerCache::UNRESTRICTED
          rescue ScriptError, StandardError => e
            Unreadable.new("#{e.class}: #{Hecks::Text.first_line(e.message)}")
          end
        end
      end
    end
  end
end
