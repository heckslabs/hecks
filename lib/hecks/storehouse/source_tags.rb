module Hecks
  # Dispatch, query and introspection over one booted domain; this file holds the list of source
  # tags a caller may name, which the MCP tool definitions show.
  module Storehouse
    # Optional on dispatch/query; omitted, source is recorded as nil rather
    # than guessed. A plain list, so the MCP tool definitions can name it without the framework.
    SOURCE_TAGS = %w[process-manager operator hook sidequest-agent cascade daemon].freeze
  end
end
