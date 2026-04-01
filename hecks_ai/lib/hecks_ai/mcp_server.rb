require "mcp"
require_relative "type_resolver"
require_relative "session_tools"
require_relative "aggregate_tools"
require_relative "aggregate_lifecycle_tools"
require_relative "inspect_tools"
require_relative "build_tools"
require_relative "play_tools"

module Hecks
  # Hecks::McpServer
  #
  # MCP (Model Context Protocol) server that exposes the Hecks Workshop API
  # as tools for AI agents. This is the main entry point for the interactive
  # domain modeling MCP server (as opposed to DomainServer which serves a
  # pre-built domain).
  #
  # Registers five tool groups:
  #   - +SessionTools+    -- create/load domain sessions
  #   - +AggregateTools+  -- add/remove domain structures
  #   - +InspectTools+    -- read-only domain introspection
  #   - +BuildTools+      -- validate, build, save, serve
  #   - +PlayTools+       -- interactive playground for testing
  #
  # The server runs over stdio transport and acts as a shared context (+ctx+)
  # for all tool modules, providing:
  #   - +session+ accessor for the current Hecks::Workshop
  #   - +ensure_session!+ guard method
  #   - +resolve_type+ for converting type strings to Ruby types
  #   - +capture_output+ for capturing stdout during block execution
  #
  #   hecks mcp    # starts the server on stdio
  #
  class McpServer
    # The current Hecks::Workshop instance, set after +create_session+ or
    # +load_domain+ tool is called. +nil+ until a session is established.
    #
    # @return [Hecks::Workshop, nil]
    attr_accessor :workshop

    # Creates a new McpServer, initializing the underlying MCP::Server and
    # registering all five tool groups with +self+ as the shared context.
    #
    # @return [McpServer]
    def initialize
      @workshop = nil
      @server = ::MCP::Server.new(name: "hecks", version: Hecks::VERSION)
      Hecks::MCP::SessionTools.register(@server, self)
      Hecks::MCP::AggregateTools.register(@server, self)
      Hecks::MCP::InspectTools.register(@server, self)
      Hecks::MCP::BuildTools.register(@server, self)
      Hecks::MCP::PlayTools.register(@server, self)
    end

    # Starts the MCP server using stdio transport. Blocks until the transport
    # is closed by the client.
    #
    # @return [void]
    def run
      require "mcp/server/transports/stdio_transport"
      ::MCP::Server::Transports::StdioTransport.new(@server).open
    end

    # Raises a RuntimeError if no session has been created yet. Called by
    # tool handlers before accessing +@workshop+.
    #
    # @raise [RuntimeError] if +@workshop+ is nil
    # @return [void]
    def ensure_session!
      raise "No session. Call create_session first." unless @workshop
    end

    # Converts a type string from MCP tool input into a Ruby type or type
    # descriptor hash. Delegates to Hecks::AI::TypeResolver.
    #
    # @param type_str [String] the type string to resolve
    # @return [Class, Hash] the resolved Ruby type or descriptor hash
    def resolve_type(type_str)
      Hecks::AI::TypeResolver.resolve(type_str)
    end

    # Returns true if the type string is a reference_to declaration.
    def reference_type?(type_str)
      Hecks::AI::TypeResolver.reference_type?(type_str)
    end

    # Extracts the target type from a reference_to string.
    def reference_target(type_str)
      Hecks::AI::TypeResolver.reference_target(type_str)
    end

    # Captures stdout during the execution of the given block and returns
    # it as a string. If the block raises, returns an error message instead.
    #
    # @yield the block whose stdout output should be captured
    # @return [String] the captured stdout output, or "Error: <message>" on failure
    def capture_output
      output = StringIO.new
      $stdout = output
      yield
      $stdout = STDOUT
      output.string
    rescue => e
      $stdout = STDOUT
      "Error: #{e.message}"
    end
  end
end
