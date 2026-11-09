# frozen_string_literal: true

module Hecks
  # Runs the load an MCP server defers to its first tool call, once, and remembers how it ended.
  #
  # A load that raises (a `LoadError` or `SyntaxError` is a `ScriptError`, which no ordinary
  # `rescue` catches) would end the process mid-session without a reply, and a retry on every
  # call would run the top level of half-loaded files again. A failed load is answered the same
  # way on every later call, without trying again. This file requires nothing, so a server can
  # load it before the framework.
  module McpLazyLoad
    # The load failed: its message is what the client is told.
    class Failed < StandardError; end

    module_function

    # @param memo [Hash] where the outcome is kept (`:done`, `:failure`); one per server
    # @yield loads what the first call needs
    # @return [void]
    # @raise [Failed] when the load raised, now or on an earlier call
    def run(memo)
      return if memo[:done]
      raise memo[:failure] if memo[:failure]

      yield
      memo[:done] = true
    rescue Failed
      raise
    rescue ScriptError, StandardError => e
      memo[:failure] = Failed.new("framework failed to load: #{e.class}: #{e.message}")
      raise memo[:failure]
    end
  end
end
