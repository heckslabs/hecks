# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # The commit a boarding names when it is not the branch's head: an older commit of the branch,
      # whose newer commits stay local. A name that is not a commit of the branch refuses the
      # boarding before anything is settled or pushed.
      class NamedCommit
        include Reading

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch the commit must be on
        def initialize(git, checkout, branch:)
          @git = git
          @checkout = checkout
          @branch = branch
        end

        # @param named [String] the commit the boarding names
        # @return [String] its full sha
        # @raise [ConsoleCapture::Failure] when it is not a commit on the branch
        def resolve(named)
          found = @git.capture("rev-parse", "--verify", "--quiet", "#{named}^{commit}", chdir: @checkout)
          sha = found.ok? ? found.out.strip : nil
          return sha if sha && ancestor?(sha, "refs/heads/#{@branch}")

          raise ConsoleCapture::Failure, "#{short(named)} is not on #{@branch}: nothing was boarded"
        end

        # @param boarded [String] the commit being carried
        # @return [Boolean] whether the local branch still holds it
        def held?(boarded) = ancestor?(boarded, "refs/heads/#{@branch}")
      end
    end
  end
end
