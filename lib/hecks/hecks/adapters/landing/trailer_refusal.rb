# frozen_string_literal: true

require_relative "../main_integration/repository"
require_relative "../main_integration/trailer_guard"
require_relative "settled_rebase"

module Hecks
  module Adapters
    module Landing
      # Refuses, at a landing, a branch whose commits do not name the run that made them, so the
      # refusal reaches the coder before main and not at boarding. It asks what boarding asks, the
      # same {MainIntegration::TrailerGuard} over the commits `onto` does not hold, and only once
      # the repository holds a trailer cutoff.
      #
      # Prepended to `GitLanding::Finisher` after {SettledRebase}, so it runs first in `rebase`:
      # after the unsaved-work check and the pull of `main`, before the rebase. The rule that a
      # commit names its run and work item moves to the Landing bluebook when the Delivery release
      # can take it (ADR 0205); until then the vendored finisher is overridden here.
      module TrailerRefusal
        private

        def rebase
          MainIntegration::TrailerGuard.new(MainIntegration::Repository.new(@checkout)).check!(@onto, "HEAD")
          super
        end
      end
    end
  end
end

Hecks::Adapters::GitLanding::Finisher.prepend(Hecks::Adapters::Landing::TrailerRefusal)
