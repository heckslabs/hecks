# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    # The `IssueTracker` port's adapter: files a `QualityControl::Ticket` as a GitHub issue.
    # Raises when `gh` refuses, which the runtime records as the ticket's refusal.
    class GithubIssues
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Files the ticket the runtime hands over (its whole held state) with `gh issue create`.
      #
      # @param held [Hash] the ticket's fields; `repository`, `title` and `body` are materialized
      #   value objects (`{value: ...}`) or bare strings, and `pull_request` names a proposed fix
      # @return [Hash{Symbol => Hash}] `number:` and `url:` of the issue, in the shape the
      #   ticket's `Filed` command takes
      # @raise [RuntimeError] when `gh` exits non-zero or prints no issue URL
      def file(**held)
        repository = plain(held[:repository])
        proposed   = plain(held[:pull_request]).to_s
        body       = plain(held[:body]).to_s
        body      += "\n\nA fix is proposed in #{proposed}" unless proposed.empty?

        out, err, status = Open3.capture3("gh", "issue", "create", "--repo", repository,
                                          "--title", plain(held[:title]).to_s, "--body", body)
        raise "gh issue create failed — #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

        url    = out.strip.lines.last.to_s.strip
        number = url[%r{/issues/(\d+)\z}, 1]
        raise "gh issue create printed no issue URL: #{out.strip.inspect}" unless number

        { number: { value: number.to_i }, url: { value: url } }
      end

      private

      # A materialized value object (`{value: x}`, symbol or string keys) or the value itself.
      def plain(field)
        return field unless field.is_a?(Hash)

        field.key?(:value) ? field[:value] : field["value"]
      end
    end
  end
end
