require "json"
require_relative "../../../tools/stage_progress"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # Where a stage's progress lines go when the client asked for them with a progress token: each
        # line becomes one `notifications/progress` message on the server's output, ahead of the
        # response to the call. Stands in for the standard error that `Tools::StageProgress` writes to.
        class ProgressSink
          # @param token [Object] the client's `progressToken`, echoed back on every notification
          # @param out [#puts] the server's output, where each notification is written
          def initialize(token, out:)
            @token = token
            @out   = out
            @count = 0
          end

          # Sends one line as a progress notification. The count rises by one per line, so a client
          # can order them.
          # @param text [String] the line
          # @return [void]
          def puts(text)
            @count += 1
            @out.puts(JSON.generate(notification(text)))
          end

          # Nothing is buffered, so there is nothing to flush.
          # @return [nil]
          def flush = nil

          private

          # @param text [String] the line
          # @return [Hash] the JSON-RPC notification carrying it
          def notification(text)
            { jsonrpc: "2.0", method: "notifications/progress",
              params: { progressToken: @token, progress: @count, message: text } }
          end
        end
      end
    end
  end
end
