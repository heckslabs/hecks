# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Raises the process's soft file descriptor limit toward its hard limit when the board
      # starts, so a launchd default of 256 does not run out under a few minutes of page loads.
      # It never lowers a limit, and a limit it cannot raise is logged, not fatal.
      module DescriptorLimit
        # The soft limit the board asks for, bounded by the hard limit.
        WANTED = 10_240

        # @param log [#call] takes one message
        # @param process [#getrlimit, #setrlimit] where the limit is read and set
        # @return [Integer, nil] the soft limit in force afterwards
        def self.raise!(log: ->(message) { warn message }, process: Process)
          soft, hard = process.getrlimit(Process::RLIMIT_NOFILE)
          want = [hard, WANTED].min
          process.setrlimit(Process::RLIMIT_NOFILE, want, hard) if want > soft
          log.call("PipelineBoard descriptor limit #{[want, soft].max}")
          [want, soft].max
        rescue SystemCallError, ArgumentError => e
          log.call("PipelineBoard could not raise the descriptor limit: #{e.message}")
          nil
        end
      end
    end
  end
end
