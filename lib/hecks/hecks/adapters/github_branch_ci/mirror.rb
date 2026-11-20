# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubBranchCi
      # The push of a coder branch's head as `ci/<branch>`. When `ci/<branch>` is absent it is a
      # plain push; when it holds another tip, as after a rebase, the push replaces it with a lease
      # pinned to the tip just read, so a write by anything else in between is refused. The
      # destination is always under `refs/heads/ci/`, which only early CI writes; which branch
      # names may be pushed is the bluebook's (`EarlyCi.Request` refuses main, stable, trains and
      # `ci/` names). A ref deleted between the read and the push refuses the leased push; the
      # same request again pushes plainly.
      class Mirror
        # The commit a `git ls-remote` line opens with.
        TIP = /\A\h+/
        # @param github [GhCall] the commands, in the coder's checkout
        def initialize(github)
          @github = github
        end

        # @param branch [String] the coder's branch
        # @param sha [String] its head
        # @return [void]
        # @raise [ConsoleCapture::Failure] when git refuses the push
        def push(branch, sha)
          ref = "refs/heads/#{PREFIX}#{branch}"
          old = tip(ref)
          lease = old.empty? || old == sha ? [] : ["--force-with-lease=#{ref}:#{old}"]
          @github.run!(["git", "push", *lease, "origin", "#{sha}:#{ref}"], "push of #{PREFIX}#{branch}")
        end

        private

        def tip(ref)
          @github.run!(["git", "ls-remote", "origin", ref], "read of #{ref}")[TIP].to_s
        end
      end
    end
  end
end
