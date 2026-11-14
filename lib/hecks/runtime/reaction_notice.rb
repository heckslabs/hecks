# frozen_string_literal: true

module Hecks
  module Runtime
    # Writes a reaction's note to stderr, and lets it go when stderr is gone.
    #
    # A command run without `--wait` returns to its caller while its reaction chain goes on, and the
    # caller's stderr may be closed by then. The note is progress, not a result, so a write that
    # finds the pipe broken is dropped: the reaction log holds what the chain did.
    module ReactionNotice
      module_function

      # @param text [String] the note
      # @return [nil]
      def say(text)
        warn(text)
      rescue Errno::EPIPE, IOError
        nil
      end
    end
  end
end
