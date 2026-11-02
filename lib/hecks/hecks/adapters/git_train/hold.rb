# frozen_string_literal: true

require_relative "../git_landing/lineup"
require_relative "../console_capture"
require "hecks/quality_control/adapters/qa_quiesce_marker"

module Hecks
  module Adapters
    class GitTrain
      # The push hold: while a boarding settles and pushes, it keeps the landing queue's front place
      # and the QA quiet marker, so no landing moves local `main` and no session starts under it.
      #
      # The place is a landing-queue ticket that beats while the hold lasts, so it expires on its
      # own when the process dies or goes silent for the world's `stale_minutes`. The marker is set
      # under the owner `push-train-<pid>` and only that owner's marker is removed again: a marker a
      # human or another job set is neither replaced nor cleared. A failure releases the hold and
      # says so in the refusal.
      class Hold
        # What the marker says the hold is for.
        REASON = "push train holding main"

        # What a refusal says once the hold is gone.
        RELEASED = "the push hold on landing was released by the failure"

        # @param git_dir [String] the repository's common git directory
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch being pushed
        # @param options [Hash] `marker:` the QA quiet marker; `lineup:` the landing line, built from
        #   `git_dir` and the other keys (limits and collaborators, see `GitLanding::Lineup`) when absent
        def initialize(git_dir, checkout, branch:, **options)
          @marker = options.delete(:marker) || QaQuiesceMarker.new
          @lineup = options.delete(:lineup) || GitLanding::Lineup.new(git_dir, **options)
          @say = options.fetch(:say) { ->(text) { warn(text) } }
          @checkout = checkout
          @branch = branch
          @owner = "push-train-#{Process.pid}"
        end

        # Runs the block holding the landing line and the QA quiet marker.
        #
        # @yieldparam story [String] who the hold waited behind and whom it holds off
        # @return [Hash] the block's answer, its report opened with the story and closed by the release
        # @raise [ConsoleCapture::Failure] when the place is not won, or the block fails (released)
        def around
          @lineup.hold(@branch, checkout: @checkout) do |note, queued|
            @held = true
            quiet = quiet_qa
            ended(yield(story = told(note, queued)), story)
          ensure
            release(quiet)
          end
        rescue ConsoleCapture::Failure => e
          raise unless @held

          raise ConsoleCapture::Failure, "#{e.message}; #{RELEASED}"
        end

        private

        def told(note, queued)
          holding = "holding landing for #{queued} queued branch#{"es" unless queued == 1}"
          @say.call("#{@branch} push: #{holding}")
          [note, holding].compact.join("; ")
        end

        def ended(answer, story)
          report = answer.dig(:report, :value)
          answer.merge(report: { value: "#{report}; push hold: #{story}, released" })
        end

        # Sets the marker unless someone else's fresh one stands; answers whether this hold set it.
        def quiet_qa
          @marker.hold!(owner: @owner, reason: REASON)
          true
        rescue QaQuiesceMarker::Refused
          false
        end

        def release(placed)
          @marker.release!(owner: @owner) if placed
        rescue QaQuiesceMarker::Refused
          nil
        end
      end
    end
  end
end
