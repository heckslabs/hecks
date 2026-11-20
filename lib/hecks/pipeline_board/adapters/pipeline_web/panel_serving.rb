# frozen_string_literal: true

require_relative "panel_cache"

module Hecks
  module Adapters
    module PipelineBoard
      # What the running board ({PipelineWeb}) answers `/api/snapshot` with: the text panel
      # `PipelineBoard.snapshot` prints, drawn from the state the board already holds and kept a
      # few seconds ({PanelCache}), so a terminal's question costs the board no reads.
      module PanelServing
        # The port a board opens on when none is given: `PipelineBoard.Serve`'s default.
        DEFAULT_PORT = 4747
        # Guards the first making of each board's {PanelCache}, which request threads share.
        MAKING = Mutex.new

        # The panel drawn from the held state, never by {PipelineStages#snapshot}, which reads
        # every source again.
        #
        # @param width [Integer, nil] the panel's columns
        # @param colour [Boolean] whether rows are coloured by their state
        # @param limit [Integer, nil] how many planned Work items and finished sessions to list
        # @return [String, nil] the panel; nil until the board holds a fresh state
        def snapshot_panel(width: nil, colour: false, limit: nil)
          panels.panel(width: width, colour: colour, limit: limit) if @snapshot.held?
        end

        # @return [PanelCache] this board's kept drawings
        def panels
          MAKING.synchronize { @panels ||= PanelCache.new(state: method(:state), train_prs: -> { @stages.train_prs }) }
        end
      end
    end
  end
end
