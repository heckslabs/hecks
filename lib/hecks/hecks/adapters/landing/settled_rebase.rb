# frozen_string_literal: true

require_relative "../delivery_library"
require_relative "rebase_settling"

Hecks::Adapters::DeliveryLibrary.require("git_landing")

module Hecks
  module Adapters
    module Landing
      # The merge fixer at a landing: a rebase that stops in conflict is carried through by
      # {RebaseSettling}, so two coders who changed different declarations of one bluebook both
      # land. A refusal, or a rebase that stopped for any other reason, is aborted as before and
      # its reason added to the vendored refusal, so `LandingRefused` names the declaration.
      #
      # The override points are the vendored `GitLanding::Finisher#rebase` and
      # `GitLanding::Train#rebase`, in the delivery package, whose files are not edited here
      # (ADR 0205). Each module below runs the same git call as the method it replaces. Whether a
      # conflict may be settled is decided here, in an adapter, because it is a parse and re-emit
      # over bluebook text; a `Settle` command on the Landing bluebook belongs to a Delivery
      # release.
      module SettledRebase
        # The fixer's reason, added after the vendored refusal when there is one.
        #
        # @param message [String] the vendored refusal
        # @param why [String, nil] why the fixer did not settle the conflict
        # @return [String] the refusal a landing reports
        def self.refusal(message, why)
          why ? "#{message}; the merge fixer refused: #{why}" : message
        end

        # Prepended to `GitLanding::Finisher`: the rebase before a landing's quick gate.
        module Finisher
          private

          def rebase
            identity = replay_identity(@checkout)
            result = @git.capture(*identity, "rebase", *rebase_range, chdir: @checkout)
            result, why = RebaseSettling.new(@git, @checkout, identity).settle(result)
            return if result.ok?

            message = "conflict: rebasing #{@branch} onto #{@onto} #{abandon_rebase(@checkout, result)}; nothing changed"
            raise ConsoleCapture::Failure, SettledRebase.refusal(message, why)
          end
        end

        # Prepended to `GitLanding::Train`: the rebase of each branch onto the moving target. The
        # train lands branches finished against an older target, so two of them can meet here in a
        # conflict no finish saw.
        module Train
          include GitMainPull::Replay

          private

          def rebase(branch)
            tree = worktree_on(branch)
            return unless tree

            result, why = settled(tree.path)
            return if result.ok?

            @git.capture("rebase", "--abort", chdir: tree.path)
            message = "#{branch} does not rebase onto #{@onto}: #{GitLanding::Train.tail(result.out, 2)}"
            raise ConsoleCapture::Failure, SettledRebase.refusal(message, why)
          end

          def settled(dir)
            identity = replay_identity(dir)
            result = @git.capture(*identity, "rebase", @onto, chdir: dir)
            RebaseSettling.new(@git, dir, identity).settle(result)
          end
        end
      end
    end
  end
end

Hecks::Adapters::GitLanding::Finisher.prepend(Hecks::Adapters::Landing::SettledRebase::Finisher)
Hecks::Adapters::GitLanding::Train.prepend(Hecks::Adapters::Landing::SettledRebase::Train)
