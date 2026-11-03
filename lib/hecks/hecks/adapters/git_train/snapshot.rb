# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # The snapshot a pinned boarding checks while it holds the line, before anything is minted
      # or pushed. The coordinator checked the remote branch at one head (`green`) and handed over
      # one commit on top of it (`pinned`). The boarding goes ahead only while the remote still
      # stands at that head, the local branch is that head plus the handoff and nothing else, and
      # the handoff changes no path beyond its own. Each failed check refuses by name; nothing is
      # pushed.
      #
      # The working tree is the check that can fire. A single-commit handoff on its green head
      # changes exactly its own paths, so the committed-tree comparison agrees with the commit
      # checks; uncommitted edits in the checkout are what can differ beyond the handoff, and the
      # mint reads the checkout, so they refuse too.
      class Snapshot
        include Reading

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch the handoff lands on, local and remote
        # @param remote [String] the remote the green head is read from
        # @param pinned [String] the handoff commit the coordinator checked
        def initialize(git, checkout, branch:, remote:, pinned:)
          @git = git
          @checkout = checkout
          @branch = branch
          @remote = remote
          @pinned = pinned
        end

        # @param green [String] the remote branch's head the coordinator checked the handoff against
        # @return [String] the pinned commit, once every check passes
        # @raise [ConsoleCapture::Failure] naming the first check that fails
        def check!(green)
          @green = green
          fetch
          remote_still_green!
          local_holds_only_handoff!
          tree_changes_only_handoff!
          @pinned
        end

        private

        def fetch = read("fetch", "--quiet", @remote, "+refs/heads/#{@branch}:refs/remotes/#{tracking}")

        def tracking = "#{@remote}/#{@branch}"

        def remote_still_green!
          now = read("rev-parse", "--verify", "#{tracking}^{commit}")
          refuse("#{@branch} moved since the check: #{short(@green)} -> #{short(now)}") unless now == @green
        end

        def local_holds_only_handoff!
          local = read("rev-parse", "--verify", "refs/heads/#{@branch}^{commit}")
          extra = read("rev-list", "#{@green}..#{local}").split("\n") - [@pinned]
          refuse("local #{@branch} holds #{extra.size} commits besides the handoff") if extra.any?
          refuse("local #{@branch} does not hold the handoff #{short(@pinned)}") unless local == @pinned
        end

        # The committed half compares the handoff's tree with green's, less what the handoff itself
        # changed; the working half compares the checkout's tracked files with the handoff's tree.
        def tree_changes_only_handoff!
          committed = paths(@green, @pinned) - paths("#{@pinned}^", @pinned)
          uncommitted = paths(@pinned)
          beyond = (committed + uncommitted).uniq
          refuse("tree differs from green beyond the handoff: #{beyond.first(5).join(", ")}") if beyond.any?
        end

        def paths(from, to = nil)
          args = ["diff", "--name-only", from, *to]
          read(*args).split("\n")
        end

        def refuse(reason) = raise(ConsoleCapture::Failure, reason)
      end
    end
  end
end
