# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # What a boarding checks before it changes a checkout: that the branch still names the commit
      # it expects, that the checkout has that branch checked out, and that nothing else is staged
      # or modified to be swept into a commit.
      class BranchGuard
        include Reading

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the boarded branch
        def initialize(git, checkout, branch)
          @git = git
          @checkout = checkout
          @branch = branch
        end

        # @return [String] the commit the branch names
        def head = read("rev-parse", "--verify", "refs/heads/#{@branch}^{commit}")

        # @param expected [String] the commit the branch must still name
        # @return [void]
        # @raise [ConsoleCapture::Failure] when the branch names another commit
        def unmoved!(expected)
          now = head
          return if now == expected

          raise ConsoleCapture::Failure,
                "#{@branch} moved since boarding (boarded #{short(expected)}, now #{short(now)}): board again"
        end

        # @return [void]
        # @raise [ConsoleCapture::Failure] when the checkout's `HEAD` is not the boarded branch
        def checked_out!
          current = @git.capture("symbolic-ref", "--quiet", "HEAD", chdir: @checkout).out.strip
          return if current == "refs/heads/#{@branch}"

          raise ConsoleCapture::Failure,
                "#{@checkout} has #{current.empty? ? "a detached HEAD" : current} checked out, not #{@branch}: " \
                "changing it would change the wrong branch; board from a checkout of #{@branch}"
        end

        # @param except [Array<String>] paths the caller wrote itself, which may be modified
        # @return [void]
        # @raise [ConsoleCapture::Failure] when the branch is not checked out, or any tracked file
        #   other than those paths is staged or modified
        def clean!(except: [])
          checked_out!
          spec = except.map { |path| ":(exclude)#{path}" }
          return if read("status", "--porcelain", "--untracked-files=no", "--", ".", *spec).empty?

          raise ConsoleCapture::Failure, "#{@checkout} has staged or modified files; commit or discard them before boarding"
        end
      end
    end
  end
end
