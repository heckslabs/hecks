# frozen_string_literal: true

require "open3"

module Hecks
  module Release
    # The message of the commit that set the version, as the owner's approval is read from it.
    #
    # A release branch merged with a merge commit leaves the version change on the merged side:
    # the first-parent commit that touches `lib/hecks/version.rb` is then the merge, whose message
    # the owner never wrote. For a merge, the message is that of the newest non-merge commit on
    # the merged side that changed the `VERSION =` line, so a bump without the trailer still
    # refuses, however the merge is worded.
    module VersionCommit
      # Raised when git cannot answer, so a release is never judged from a guess.
      class GitFailed < StandardError; end

      VERSION_LINE = "^ *VERSION = "
      VERSION_FILE = "lib/hecks/version.rb"

      module_function

      # @param commit [String] the first-parent commit that touches the version file
      # @param dir [String] the git work tree
      # @return [String] the message of the commit that set the version
      def message(commit, dir: Dir.pwd)
        parents = git(dir, "rev-list", "--parents", "-n", "1", commit).split.drop(1)
        side = parents.size > 1 ? side_message(dir, commit, parents) : ""
        side.strip.empty? ? git(dir, "log", "-1", "--format=%B", commit) : side
      end

      # @return [String] the newest non-merge bump on the merged side, or "" when it has none
      def side_message(dir, commit, parents)
        git(dir, "log", "--no-merges", "-1", "--format=%B", "-G#{VERSION_LINE}", "#{parents.first}..#{commit}",
            "--", VERSION_FILE)
      end

      # @return [String] what `git` prints in `dir`
      # @raise [GitFailed] when git refuses
      def git(dir, *args)
        out, status = Open3.capture2e("git", "-C", dir, *args)
        raise GitFailed, "git #{args.join(" ")} failed: #{out}" unless status.success?

        out
      end
    end
  end
end
