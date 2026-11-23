# frozen_string_literal: true

require "open3"

module Hecks
  module Release
    # Whether a tag that stands on another commit is nevertheless this release.
    #
    # A release branch merged with a merge commit leaves the tag on the bump commit on the merged
    # side, while the first-parent commit that set the version is the merge. A tag on an ancestor
    # of the release commit whose `lib/hecks/version.rb` names the same version is the release
    # that exists. The tag stays where it is; the later steps build from the release commit, so
    # the files the tag carries and the ones released may differ in what the merge brought in.
    module SameRelease
      VERSION_FILE = "lib/hecks/version.rb"
      # The `VERSION = "x.y.z"` line of the version file.
      VERSION_LINE = /^ *VERSION = "(.*)"/

      module_function

      # @param tag_commit [String] the commit the tag stands on
      # @param commit [String] the release commit
      # @param version [String] the release's version, such as "7.1.0"
      # @param dir [String] the git work tree
      # @return [Boolean] whether the tag is the release of this commit
      def stands?(tag_commit:, commit:, version:, dir: Dir.pwd)
        return false unless git(dir, "merge-base", "--is-ancestor", tag_commit, commit)

        text = git(dir, "show", "#{tag_commit}:#{VERSION_FILE}")
        text.to_s[VERSION_LINE, 1] == version
      end

      # @return [String, nil] git's output (a space for a silent success), nil on failure
      def git(dir, *)
        out, status = Open3.capture2("git", "-C", dir, *, err: File::NULL)
        status.success? ? "#{out} " : nil
      end
    end
  end
end
