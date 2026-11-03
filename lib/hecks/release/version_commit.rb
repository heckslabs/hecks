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

      # The one definition of "the commit that set the version": the newest first-parent commit
      # that touches the `VERSION =` line. `release.yml` (through `ruby -r hecks/release/version_commit`)
      # and `publishing_run.publish` (the release facts) both ask this, so a bump that arrives in a
      # merge is judged the same way by both.
      #
      # @param dir [String] the git work tree
      # @param ref [String] where the search starts, `HEAD` unless a run stands elsewhere
      # @return [String] the commit's id, empty when no commit sets the version
      def commit(dir: Dir.pwd, ref: "HEAD", reader: nil)
        ask(dir, reader, "log", "--first-parent", "-1", "--format=%H", "-G#{VERSION_LINE}", ref, "--", VERSION_FILE).strip
      end

      # @param commit [String] the first-parent commit that touches the version file
      # @param dir [String] the git work tree
      # @return [String] the message of the commit that set the version
      def message(commit, dir: Dir.pwd, reader: nil)
        parents = ask(dir, reader, "rev-list", "--parents", "-n", "1", commit).split.drop(1)
        side = parents.size > 1 ? side_message(dir, reader, commit, parents) : ""
        side.strip.empty? ? ask(dir, reader, "log", "-1", "--format=%B", commit) : side
      end

      # @return [String] the newest non-merge bump on the merged side, or "" when it has none
      def side_message(dir, reader, commit, parents)
        ask(dir, reader, "log", "--no-merges", "-1", "--format=%B", "-G#{VERSION_LINE}", "#{parents.first}..#{commit}",
            "--", VERSION_FILE)
      end

      # @param reader [#read, nil] answers a git command in the checkout, as the release facts'
      #   runner
      #   does; nil runs `git` in `dir`
      # @return [String] what git prints for the arguments
      def ask(dir, reader, *) = reader ? reader.read(*) : git(dir, *)

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
