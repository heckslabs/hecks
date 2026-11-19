# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    # The `SubmittedPaths` port's adapter for `ChangeReview`: reads the paths a submitted commit
    # changed against main, and the commit's tree, in the checkout it was submitted from.
    #
    # It runs `git diff --name-only main...<commit>` and `git rev-parse <commit>^{tree}` with an
    # argument list, never a shell, and judges nothing: which paths ask for the architect is the
    # bluebook's given. Each path is answered between bars (`|a.bluebook|b.rb|`), so a given
    # matches a path whole.
    class SubmittedPaths
      # The checkout or the commit could not be read; the message is git's own.
      class Unread < StandardError; end

      # @param git [#call, nil] stand-in: takes the argv, answers `[stdout, stderr, status]`
      def initialize(git: nil)
        @git = git || ->(argv) { Open3.capture3(*argv) }
      end

      # @param review [Hash, String] the submitted commit
      # @param checkout [Hash, String] the directory it was submitted from
      # @return [Hash{Symbol => Hash}] `paths:` the changed paths, each between bars, and `tree:`
      #   the commit's tree
      # @raise [Unread] naming why git could not read them
      def submitted_paths(review:, checkout:, **)
        commit = plain(review)
        dir = plain(checkout)
        listing = read(commit, dir, "diff", "--name-only", "main...#{commit}")
        { paths: { value: barred(listing) }, tree: { value: read(commit, dir, "rev-parse", "#{commit}^{tree}").strip } }
      end

      private

      def read(commit, dir, *args)
        out, err, status = @git.call(["git", "-C", dir, *args])
        raise Unread, "git could not read the paths #{commit} changed: #{err.strip}" unless status.success?

        out
      end

      # Each path of git's listing between bars: `|a.bluebook|b.rb|`.
      def barred(listing)
        paths = listing.lines.map(&:strip).reject(&:empty?)
        "|#{paths.join("|")}|"
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
