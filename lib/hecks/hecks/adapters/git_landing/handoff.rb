# frozen_string_literal: true

require_relative "job"

module Hecks
  module Adapters
    class GitLanding
      # A submitted landing: handed to a job of its own, so the caller does not wait for the
      # rebase, the gate or the line. The including class answers `settle`, `plain`, `primary`,
      # `current_branch`, `finish_branch`, `retire_from_primary`, `@checkout` and `@tune`.
      module Handoff
        # Starts the landing job of a worktree's branch and answers at once. It refuses nothing
        # about the branch: the job's own landing does, and reports it as `LandingRefused`.
        #
        # @param held [Hash] the `Landing` record: `checkout`, `branch` and `onto`
        # @return [Hash{Symbol => Hash}] `outcome:` (`handed`), `checkout:`, `branch:`, `report:`
        # @raise [ConsoleCapture::Failure] when the primary checkout has no launcher to run it
        def start_landing(**held)
          settle(held)
          branch = plain(held[:branch]) || current_branch
          job = Job.new(primary.path, spawner: @tune[:spawner], logs: @tune[:logs])
          said = job.start(checkout: @checkout, branch: branch, onto: plain(held[:onto]) || "main")
          { outcome: { value: "handed" }, checkout: { value: @checkout }, branch: { value: branch }, report: { value: said } }
        end

        # Finishes a branch as its landing job does: every step of {#finish_branch}, but the
        # worktree is kept, since the reviewer works in it and a reopened Work item's next coder
        # starts from it.
        #
        # @param held [Hash] the `Landing` record, as for {#finish_branch}
        # @return [Hash{Symbol => Hash}] the answer {#merge} gives
        # @raise [ConsoleCapture::Failure] at the first step that fails, naming it
        def carry_branch(**held)
          @keeping = true
          finish_branch(**held)
        ensure
          @keeping = false
        end

        private

        # What a landing leaves behind: a job's landing keeps the worktree, a finish retires the
        # one it ran in, and a plain landing tidies what holds nothing `onto` lacks.
        def tidied(branch, onto)
          return "kept #{branch}: its worktree stays for the review; retire it with Landing.retire! --confirm" if @keeping
          return retire_from_primary(branch, onto) if @retiring

          Tidy.new(@git, @checkout, branch: branch, onto: onto).call
        end
      end
    end
  end
end
