require_relative "../../../mcp_lazy_load"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # What the MCP server loads late, and keeps. The framework and the tool implementations load
        # on the first call that needs them, so an idle server holds only the interpreter, the stdio
        # guard and the static tool definitions; a restricted server keeps each domain it serves
        # booted between calls. `initialize`, `ping` and `tools/list` of an unrestricted or reader
        # server are answered from the static definitions and the scope alone; a commands server
        # loads the framework at `tools/list`, which reads its command guide from a booted domain.
        module Loading
          # Loads the framework, the tool implementations, the progress seam and the guide cache,
          # once. Nothing a request that only reads the static definitions needs is in here. A load
          # that fails is answered the same way on every later call, not tried again.
          #
          # @return [void]
          # @raise [McpLazyLoad::Failed] when the load raised
          def framework!
            McpLazyLoad.run(load_state) do
              require_relative "../../.."
              require_relative "tool_calls"
              require_relative "progress_sink"
              require_relative "../mcp_guide_cache"
            end
          end

          # @return [Hash] how the late load ended, kept by {McpLazyLoad.run}
          def load_state = (@load_state ||= {})

          # Runs the block with a progress seam for this call's stages, so their lines reach the
          # client as notifications. The seam is per thread and removed when the call ends.
          # @param token [Object] the client's progress token
          # @return [Object] the block's value
          def with_progress(token)
            framework!
            previous = Thread.current[:mcp_progress]
            Thread.current[:mcp_progress] = Tools::StageProgress.new(ProgressSink.new(token, out: $stdout))
            yield
          ensure
            Thread.current[:mcp_progress] = previous
          end

          # The progress seam of the call on this thread: nil when the client sent no token.
          # @return [Tools::StageProgress, nil]
          def progress = Thread.current[:mcp_progress]

          # The runtime a restricted server keeps for `path`, booted again once its files change.
          #
          # @param path [String] the confined domain directory
          # @return [Runtime::Dispatcher] the booted domain
          def resident_boot(path)
            resident    = (@resident ||= {})
            fingerprint = Storehouse.fingerprint(path)
            return resident[path][:runtime] if resident[path] && resident[path][:fingerprint] == fingerprint

            resident[path] = { fingerprint: fingerprint, runtime: Hecks.boot(path, install_driving: false) }
            resident[path][:runtime]
          end
        end
      end
    end
  end
end
