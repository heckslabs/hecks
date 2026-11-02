# frozen_string_literal: true

module Hecks
  module Tools
    # Streams one line per check as the check starts and as it ends, so a long stage shows its
    # progress before its verdict. Each line is written and flushed as it happens.
    #
    # Lines go to the real standard error by default, not to `$stderr`: a recorded run captures
    # `$stderr` into its journal, and the progress would be swallowed there. The verdict stays on
    # standard output, so a pipe still receives only the result.
    class StageProgress
      class << self
        # Whether the lines are left out, as `-q` asks: set by the launcher for the length of a
        # line.
        # @return [Boolean]
        attr_accessor :quiet
      end
      self.quiet = false

      # @param io [#puts, #flush] where the lines are written; the process's own standard error
      #   (file descriptor 2), whatever `$stderr` is redirected to at the time
      def initialize(io = IO.new(2, "w", autoclose: false))
        @io = io
        @lock = Mutex.new
      end

      # @param id [String] the check's id
      # @return [void] the line saying the check has started
      def start(id)
        line("start #{id}")
      end

      # @param id [String] the check's id
      # @param passed [Boolean] whether the check exited 0
      # @param seconds [Float] how long it ran
      # @return [void] the line saying how the check ended
      def finish(id, passed, seconds)
        line("#{passed ? "ok" : "fail"} #{id} #{format("%.1fs", seconds)}")
      end

      private

      # @param text [String] one line, written and flushed under a lock so threads do not interleave
      # @return [void]
      def line(text)
        return if self.class.quiet

        @lock.synchronize do
          @io.puts(text)
          @io.flush
        end
      end
    end
  end
end
