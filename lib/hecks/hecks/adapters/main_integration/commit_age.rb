# frozen_string_literal: true

require "open3"
require "time"

module Hecks
  module Adapters
    class MainIntegration
      # When a run's landed commit was committed, read from the checkout the run landed in: the one
      # clock a run with no tap line still has. Answers nothing when the checkout is unknown or git
      # cannot say, so such a run is never taken for stale.
      class CommitAge
        # @param run [Runs::Run] the run, whose landed commit and checkout are read
        # @return [Time, nil] the commit's committer time; nil when it cannot be read
        def committed(run)
          return nil if run.checkout.to_s.empty? || !Dir.exist?(run.checkout)

          out, status = Open3.capture2("git", "-C", run.checkout, "show", "-s", "--format=%ct", run.landed,
                                       err: File::NULL)
          status.success? ? Time.at(Integer(out.strip)).utc : nil
        rescue ArgumentError, SystemCallError
          nil
        end
      end
    end
  end
end
