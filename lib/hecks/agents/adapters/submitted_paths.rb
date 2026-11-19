# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    # The `SubmittedPaths` port's adapter for `ChangeReview`: reads the paths a submitted commit
    # changed against main, in the checkout it was submitted from.
    #
    # It runs `git diff --name-only main...<commit>` with an argument list, never a shell, and
    # judges nothing: which paths ask for the architect is the bluebook's given. Each path is
    # answered between bars (`|a.bluebook|b.rb|`), so a given matches a path whole.
    class SubmittedPaths
      # The checkout or the commit could not be read; the message is git's own.
      class Unread < StandardError; end

      # @param git [#call, nil] stand-in: takes the argv, answers `[stdout, stderr, status]`
      def initialize(git: nil)
        @git = git || ->(argv) { Open3.capture3(*argv) }
      end

      # @param review [Hash, String] the submitted commit
      # @param checkout [Hash, String] the directory it was submitted from
      # @return [Hash{Symbol => Hash}] `paths:` the changed paths, each between bars
      # @raise [Unread] naming why git could not read them
      def submitted_paths(review:, checkout:, **)
        commit = plain(review)
        out, err, status = @git.call(["git", "-C", plain(checkout), "diff", "--name-only", "main...#{commit}"])
        raise Unread, "git could not read the paths #{commit} changed: #{err.strip}" unless status.success?

        { paths: { value: barred(out) } }
      end

      private

      # Each path of git's listing between bars: `|a.bluebook|b.rb|`.
      def barred(listing)
        paths = listing.lines.map(&:strip).reject(&:empty?)
        "|#{paths.join("|")}|"
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
