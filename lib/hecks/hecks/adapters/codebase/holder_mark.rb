# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # Who already holds a heavy-job place, so a job started under it never queues behind it. A
      # parent process's `HECKS_HEAVY_SLOT_HELD` covers every child; this process's own mark covers
      # only the thread that holds, so a second command of one process takes a place of its own.
      module HolderMark
        # The environment variable a holder sets for the children it starts.
        ENV_NAME = "HECKS_HEAVY_SLOT_HELD"

        # @param base [#[]] the environment
        # @return [Boolean] true when a parent holds, CI runs, or this thread holds under the real
        #   environment
        def self.covers?(base)
          parent = ![Process.pid.to_s, ""].include?(base[ENV_NAME].to_s)
          parent || !base["CI"].to_s.empty? || (base.equal?(ENV) && Thread.current[:heavy_slot_held] == true)
        end

        # @param held [Boolean] whether the current thread holds a place
        # @return [void]
        def self.set(held) = Thread.current[:heavy_slot_held] = held
      end
    end
  end
end
