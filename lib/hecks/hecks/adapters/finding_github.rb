# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    # The `GitHubIssues` port's adapter: drives one GitHub issue from a `Tickets::Finding` with
    # `gh`.
    #
    # Nothing is opened until a repository is named, by the `repository` setting or the
    # `HECKS_FINDINGS_REPO` environment variable (`owner/name`); without one every ask is refused,
    # and the runtime records the refusal on the finding. An ask that needs the issue before one
    # was opened is refused the same way, so a finding never blocks on GitHub.
    class FindingGithub
      # Raised when `gh` cannot file or find the finding's issue.
      class Error < RuntimeError; end

      # The environment variable that names the repository when no setting does.
      REPOSITORY_VARIABLE = "HECKS_FINDINGS_REPO"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `repository:` names the `owner/name` to drive
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @repository = settings[:repository]
      end

      # Opens an issue for the finding the runtime hands over (its whole held state).
      #
      # @param held [Hash] the finding's fields; `title` and `body` are value objects or strings
      # @return [Hash{Symbol => Hash}] `issue_number:` of the new issue, the shape
      #   `Finding.RecordIssue` takes
      # @raise [Error] when no repository is named, `gh` exits non-zero, or prints no
      #   issue URL
      def open_issue(**held)
        out = gh("issue", "create", "--title", plain(held[:title]).to_s, "--body", plain(held[:body]).to_s)
        number = out.lines.last.to_s.strip[%r{/issues/(\d+)\z}, 1]
        raise Error, "gh issue create printed no issue URL: #{out.strip.inspect}" unless number

        { issue_number: { value: number.to_i } }
      end

      # Puts the finding's kind and severity on its issue as labels.
      #
      # @param held [Hash] the finding's fields
      # @return [Hash{Symbol => Hash}] `output:` the line that says what was done
      def label_issue(**held)
        labels = [["kind", held[:kind]], ["severity", held[:severity]]]
                 .map { |name, field| "#{name}:#{plain(field)}" unless plain(field).to_s.empty? }.compact
        return said("no kind or severity to label") if labels.empty?

        gh("issue", "edit", issue(held), "--add-label", labels.join(","))
        said("labelled #{labels.join(", ")}")
      end

      # Comments on the issue with the pull request that fixes the finding.
      #
      # @param held [Hash] the finding's fields
      # @return [Hash{Symbol => Hash}] `output:` the line that says what was done
      def comment_on_issue(**held)
        gh("issue", "comment", issue(held), "--body", "A fix is proposed in ##{plain(held[:fix_pr_number])}")
        said("commented with the fix")
      end

      # Closes the issue: as completed for a resolved finding, as not planned for a dismissed one.
      #
      # @param held [Hash] the finding's fields, `status` among them
      # @return [Hash{Symbol => Hash}] `output:` the line that says what was done
      def close_issue(**held)
        reason = plain(held[:status]) == "dismissed" ? "not planned" : "completed"
        gh("issue", "close", issue(held), "--reason", reason)
        said("closed as #{reason}")
      end

      # Reopens the issue of a finding taken back to triaged.
      #
      # @param held [Hash] the finding's fields
      # @return [Hash{Symbol => Hash}] `output:` the line that says what was done
      def reopen_issue(**held)
        gh("issue", "reopen", issue(held))
        said("reopened")
      end

      private

      def gh(*arguments)
        out, err, status = Open3.capture3("gh", *arguments, "--repo", repository)
        unless status.success?
          raise Error,
                "gh #{arguments.first(2).join(" ")} failed — #{err.strip.empty? ? out.strip : err.strip}"
        end

        out
      end

      def repository
        name = @repository || ENV.fetch(REPOSITORY_VARIABLE, nil)
        return name unless name.to_s.strip.empty?

        raise Error, "no repository named: set the `repository` setting or #{REPOSITORY_VARIABLE} to owner/name"
      end

      def issue(held)
        number = plain(held[:issue_number])
        raise Error, "the finding has no GitHub issue yet" if number.to_s.empty?

        number.to_s
      end

      def said(line) = { output: { value: line } }

      # A materialized value object (`{value: x}`, symbol or string keys) or the value itself.
      def plain(field)
        return field unless field.is_a?(Hash)

        field.key?(:value) ? field[:value] : field["value"]
      end
    end
  end
end
