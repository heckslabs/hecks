# frozen_string_literal: true

require "hecks/checkout_caches"
require_relative "../delivery_library"

Hecks::Adapters::DeliveryLibrary.require("git_landing")

module Hecks
  module Adapters
    module Landing
      # A retired worktree takes its caches with it: the Cargo slot it built into below the shared
      # target and its compiled-Ruby cache ({CheckoutCaches}), which live outside the worktree and
      # which nothing reads once it is gone.
      #
      # The override point is the vendored `GitLanding::Tidy#drop`, in the delivery package, whose
      # files are not edited here (ADR 0205). Every removal of a session's worktree passes through
      # it: `Landing.retire!`, `Landing.discard!`, the tidy after a landing and the session reap.
      # The temporary worktrees a merge, a rehearsal or the push train make are removed elsewhere;
      # a slot one of them left goes with `Build.prune_rust!`.
      module RetiredCaches
        private

        # Names the worktree's caches while it stands, since the spelling the file system gave its
        # path cannot be read afterwards, and removes them only once the worktree is gone. A
        # worktree that is kept (git refused, the branch moved) keeps its caches.
        #
        # @param path [String] the worktree's directory
        # @param tip [String] the commit its branch was verified at
        # @return [Array(Boolean, String)] what the vendored method answers, unchanged
        def drop(path, tip)
          caches = CheckoutCaches.of(path)
          super.tap { CheckoutCaches.remove(caches) unless File.exist?(path) }
        end
      end
    end
  end
end

Hecks::Adapters::GitLanding::Tidy.prepend(Hecks::Adapters::Landing::RetiredCaches)
