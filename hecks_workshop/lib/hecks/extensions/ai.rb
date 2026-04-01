# Hecks AI Extension (MCP)
#
# Top-level extension registration and autoload file for the MCP (Model Context
# Protocol) integration. This file:
#
# 1. Describes the +:mcp+ extension to Hecks (with default port config)
# 2. Registers the extension so that any domain module gains a +.mcp+ method
#    that starts an MCP server
# 3. Sets up autoloads for all MCP tool modules, the connection adapter, and
#    the McpServer class
#
# The MCP extension exposes domain commands, queries, and session tools to AI
# agents via the Model Context Protocol, enabling AI-assisted domain modeling.
#
# Future gem: hecks_ai
#
#   require "hecks_ai"
#   Hecks::McpServer.new.run
#
Hecks.describe_extension(:mcp,
  description: "MCP server for AI-assisted domain modeling",
  adapter_type: :driving,
  config: { gate: { default: 8080, desc: "MCP server port" } },
  wires_to: :domain)

# Registers the +:mcp+ extension. When activated on a domain module, it defines
# a +.mcp+ singleton method that instantiates and runs an McpServer.
#
# @param domain_mod [Module] the generated domain module receiving the extension
# @param domain [Hecks::DomainModel::Structure::Domain] the domain model object
# @param _runtime [Hecks::Runtime] the runtime instance (unused)
Hecks.register_extension(:mcp) do |domain_mod, domain, _runtime|
  domain_mod.define_singleton_method(:mcp) do |**opts|
    Hecks::McpServer.new(**opts).run
  end
end

module Hecks
  # Namespace for MCP (Model Context Protocol) tool modules.
  # Each sub-module registers a group of tools with an MCP server instance.
  #
  # Tool groups:
  # - +DomainServer+  -- generates an MCP server from an existing domain
  # - +SessionTools+  -- create/load domain modeling sessions
  # - +AggregateTools+ -- add/remove aggregates, commands, value objects, etc.
  # - +InspectTools+  -- read-only domain introspection
  # - +BuildTools+    -- validate, build gem, save DSL, serve HTTP
  # - +PlayTools+     -- interactive playground for testing commands
  module MCP
    autoload :DomainServer,  "hecks/extensions/ai/domain_server"
    autoload :SessionTools,  "hecks/extensions/ai/session_tools"
    autoload :AggregateTools, "hecks/extensions/ai/aggregate_tools"
    autoload :InspectTools,  "hecks/extensions/ai/inspect_tools"
    autoload :BuildTools,    "hecks/extensions/ai/build_tools"
    autoload :PlayTools,     "hecks/extensions/ai/play_tools"
  end

  # Namespace for connection adapters that wire external transports to a domain.
  module Connections
    autoload :McpConnection, "hecks/extensions/ai/connection"
  end

  autoload :McpServer, "hecks/extensions/ai/mcp_server"
end
