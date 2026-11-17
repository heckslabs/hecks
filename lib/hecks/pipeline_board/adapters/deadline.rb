# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Runs a block with a bound: it answers the block's value, or, once the seconds have passed,
      # stops the block's thread and raises {Overdue}, so a call that never returns costs the
      # caller its bound and no more.
      module Deadline
        # The block did not answer within its bound.
        class Overdue < StandardError; end

        # @param seconds [Numeric] how long the block may run
        # @param what [String] named in the {Overdue} message
        # @yield the work to bound
        # @return [Object] what the block answered
        # @raise [Overdue] when the block ran past its bound
        # @raise [StandardError] whatever the block raised
        def self.run(seconds, what = "the call", &)
          thread = Thread.new(&)
          thread.report_on_exception = false
          return thread.value if thread.join(seconds)

          thread.kill
          raise Overdue, "#{what} did not answer in #{seconds}s"
        end
      end
    end
  end
end
