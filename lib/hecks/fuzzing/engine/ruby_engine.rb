module Hecks
  module Fuzzing
    module Engine
      # Runs a step list in-process through {Replay}, unchanged.
      class RubyEngine
        # @param domain_path [String] the domain directory to replay
        # @param steps [Array<Hash>] the step list
        # @param options [Hash] the keywords `Replay.call` takes
        # @return [Hash] the history `Replay.call` returns
        def call(domain_path, steps, **)
          Replay.call(domain_path, steps, **)
        end
      end
    end
  end
end
