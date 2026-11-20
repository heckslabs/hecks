# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Engine
      # The Ruby runtime as an engine: each call is today's `Replay.call`, a fresh isolated boot
      # per sequence, unchanged. Its history also holds the oracle traces every property reads.
      class Ruby
        # @param domain_path [String] the domain directory to replay
        # @param steps [Array<Hash>] the step list
        # @param identity [Array<String>, nil] the ids the identity port hands out, in order
        # @return [Hash] the history `Replay.call` returns
        def call(domain_path, steps, identity: nil)
          Replay.call(domain_path, steps, identity: identity)
        end
      end
    end
  end
end
