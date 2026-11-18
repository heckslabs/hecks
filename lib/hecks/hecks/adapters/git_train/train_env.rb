# frozen_string_literal: true

module Hecks
  module Adapters
    class GitTrain
      # The environment a boarding's own checks run in. It carries the train's mark in the form git
      # hands a hook (`GIT_CONFIG_PARAMETERS`), which the heavy-job queue reads to rank a job as the
      # train's rather than ordinary, so a check a boarding runs waits as long as its push does.
      module TrainEnv
        # @param commit [String] the commit the boarding carries
        # @param base [#[]] the environment to extend
        # @return [Hash{String => String}] the variable to set for a child process
        def self.for(commit, base = ENV)
          mark = "'hecks.trainCarry=#{commit}'"
          held = base["GIT_CONFIG_PARAMETERS"].to_s
          { "GIT_CONFIG_PARAMETERS" => [held, mark].reject(&:empty?).join(" ") }
        end
      end
    end
  end
end
