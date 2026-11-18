# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubBranchCi
      # The draft pull request a `ci/<branch>` runs CI under: the open one from that head, or a new
      # draft against main. A draft runs the `pull_request` jobs a train's pull request runs, and is
      # never auto-merged nor queued.
      class Draft
        # @param github [GhCall] the calls to GitHub
        def initialize(github)
          @github = github
        end

        # @param head [String] the pushed branch, `ci/<branch>`
        # @param branch [String] the coder's branch, for the title
        # @return [String] the draft's number
        def number(head, branch)
          found = Array(@github.api("pulls?state=open&head={owner}:#{head}&per_page=1")).first
          (found || opened(head, branch))["number"].to_s
        end

        private

        def opened(head, branch)
          @github.api("pulls", "--method", "POST", "-f", "head=#{head}", "-f", "base=main", "-F", "draft=true",
                      "-f", "title=ci: #{branch}", "-f", "body=CI for #{branch} before its coder hands off. Never merged.")
        end
      end
    end
  end
end
