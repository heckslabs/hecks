module RuboCop
  module Cop
    module Hecks
      # Flags a duration measured as `Time.now - start`, where `start` was itself read from the clock.
      #
      # The wall clock steps backwards and forwards (NTP corrections), so a subtraction can go
      # negative or jump. Elapsed time comes from the monotonic clock. `Time.now - seconds` (a past
      # timestamp) and `Time.now - File.mtime(path)` (an age against a stored time) are left alone.
      #
      # @example
      #   started = Time.now
      #   elapsed = Time.now - started                                         # bad
      #
      #   started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      #   elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started  # good
      class MonotonicDuration < Base
        MSG = "`Time.now - %<start>s` measures elapsed time on the wall clock, which can step. " \
              "Take both ends from `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.".freeze

        # @!method wall_clock_minus_variable(node)
        def_node_matcher :wall_clock_minus_variable, <<~PATTERN
          (send #clock_read? :- ${lvar ivar})
        PATTERN

        # @!method clock_read?(node)
        def_node_matcher :clock_read?, <<~PATTERN
          {(send (const {nil? cbase} :Time) :now) (send (send (const {nil? cbase} :Time) :now) :to_f)}
        PATTERN

        # Flags `Time.now - <variable>` when the variable holds an earlier clock read.
        #
        # @param node [RuboCop::AST::SendNode] the subtraction being visited
        # @return [void]
        def on_send(node)
          start = wall_clock_minus_variable(node)
          return unless start && assigned_from_clock?(node, start)

          add_offense(node, message: format(MSG, start: start.source))
        end

        private

        # Whether the variable is assigned a clock read anywhere in the enclosing method or class.
        def assigned_from_clock?(node, variable)
          scope = node.each_ancestor(:def, :defs, :class, :module).first || processed_source.ast
          scope.each_descendant(:lvasgn, :ivasgn).any? do |assignment|
            assignment.name == variable.children.first && clock_read?(assignment.expression)
          end
        end
      end
    end
  end
end
