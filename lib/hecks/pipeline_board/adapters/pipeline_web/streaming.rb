# frozen_string_literal: true

require_relative "stream"

module Hecks
  module Adapters
    module PipelineBoard
      # The page's event stream, as the app answers it: a {Stream} over the journal's hub that reads
      # the wiring without waiting on the lock of a rebuild.
      module Streaming
        # Yields each event the held state lists once and again when its reactions change, the state
        # whenever it changes, the wiring's digest whenever the bluebooks are drawn differently, and
        # the HTML of each tile a journal line changed, until the reader goes away. It acts when the
        # journal grows, not on a clock.
        #
        # @yieldparam event [Hash] an event row, an `unknown` note, a `state` hash, a `wiring` digest,
        #   a `tile` fragment or a heartbeat
        def stream(gone: nil, &)
          wiring = @wiring.method(:held_reading)
          PipelineBoard::Stream.new(hub: @pushed.hub, state: method(:state), wiring: wiring, gone: gone).each(&)
        end
      end
    end
  end
end
