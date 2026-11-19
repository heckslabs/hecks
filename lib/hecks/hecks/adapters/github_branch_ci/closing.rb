# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubBranchCi
      # The close of a landed branch's `ci/<branch>`: its open draft pull request is closed, never
      # merged, and the pushed branch is deleted, over REST. A draft already closed or a branch
      # already gone is nothing to do, so a second close answers as the first did.
      class Closing
        # @param github [GhCall] the calls to GitHub
        def initialize(github)
          @github = github
        end

        # @param head [String] the pushed branch, `ci/<branch>`
        # @return [Hash{Symbol => String}] `number`, the draft closed (empty when none was open),
        #   and `report`
        # @raise [ConsoleCapture::Failure] when GitHub refuses for any cause but a missing branch
        def close(head)
          number = closed_draft(head)
          deleted = delete(head)
          { number: number, report: report(head, number, deleted) }
        end

        private

        def closed_draft(head)
          found = Array(@github.api("pulls?state=open&head={owner}:#{head}&per_page=1")).first
          return "" unless found

          @github.api("pulls/#{found["number"]}", "--method", "PATCH", "-f", "state=closed")
          found["number"].to_s
        end

        def delete(head)
          @github.run!(["gh", "api", "--method", "DELETE", "repos/{owner}/{repo}/git/refs/heads/#{head}"],
                       "delete of #{head}")
          true
        rescue ConsoleCapture::Failure => e
          raise unless e.message.include?("Reference does not exist") || e.message.include?("Not Found")

          false
        end

        def report(head, number, deleted)
          draft = number.empty? ? "no open draft" : "closed draft ##{number}"
          "#{draft} for #{head}; #{deleted ? "deleted" : "no"} branch #{head}"
        end
      end
    end
  end
end
