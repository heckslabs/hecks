# frozen_string_literal: true

require "monitor"

module Hecks
  module Adapters
    module PipelineBoard
      # The one lock every boot or description of a domain in the board process goes through.
      #
      # `Hecks.describe`, `Hecks.boot` and `Hecks.with_registry` set a registry that the whole
      # process sees as current, not one per thread, so two of them at once can register one
      # domain's declarations in the other's registry. The board runs several: the live store's
      # boot on its own thread, the readers that describe a bluebook, and the wiring page's
      # reload. They take turns.
      module BootLock
        LOCK = Monitor.new

        module_function

        # Runs the block as the only boot or description in the process.
        # @yield the boot, description or registry-setting reload
        # @return [Object] the block's result
        def exclusive(&) = LOCK.synchronize(&)
      end
    end
  end
end
