module RuboCop
  module Cop
    module Hecks
      # Flags a duration measured as `Time.now - start`.
      #
      # The wall clock steps backwards and forwards (NTP, DST-free but still adjusted), so a
      # subtraction can go negative or jump. Elapsed time comes from the monotonic clock.
      # `Time.now - File.mtime(path)` is an age against a stored wall-clock time and is left alone.
      #
      # @example
      #   elapsed = Time.now - started                                      # bad
      #   elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started  # good
      class MonotonicDuration < Base
        MSG = "`Time.now - %<start>s` measures elapsed time on the wall clock, which can step. " \
              "Take both ends from `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.".freeze

        # @!method wall_clock_minus_local(node)
        def_node_matcher :wall_clock_minus_local, <<~PATTERN
          (send {(send (const {nil? cbase} :Time) :now) (send (send (const {nil? cbase} :Time) :now) :to_f)} :-
            ${lvar ivar})
        PATTERN

        # Flags `Time.now - <variable>`.
        #
        # @param node [RuboCop::AST::SendNode] the subtraction being visited
        # @return [void]
        def on_send(node)
          start = wall_clock_minus_local(node)
          return unless start

          add_offense(node, message: format(MSG, start: start.source))
        end
      end
    end
  end
end
