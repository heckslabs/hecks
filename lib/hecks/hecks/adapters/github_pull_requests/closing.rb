# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubPullRequests
      # The `Shut` ask of the `GitHubPullRequests` port: closes one open pull request by its
      # number, with a comment saying why. It keeps the branch and never merges.
      module Closing
        # Closes one open pull request by its number, with a comment saying why. The comment is
        # one argv element, never passed through a shell.
        #
        # @param held [Hash] the `ReviewRequest` record: `number` and `comment` (both required)
        # @return [Hash{Symbol => Hash}] `report:` naming the pull request closed and why
        # @raise [ConsoleCapture::Failure] when no number or comment is named, the pull request is
        #   not open, or GitHub refuses
        def shut(**held)
          number = pull_request_number(held[:number], "close")
          comment = plain(held[:comment]).to_s
          raise ConsoleCapture::Failure, "no comment to close ##{number} with: say why" if comment.strip.empty?

          ensure_open!(number)
          gh!("pr", "close", number, "--comment", comment)
          { report: { value: "closed ##{number}: #{comment}" } }
        end
      end
    end
  end
end
