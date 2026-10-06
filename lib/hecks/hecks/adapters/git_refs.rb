# frozen_string_literal: true

require_relative "console_capture"

module Hecks
  module Adapters
    # The ref calls of the `Git` adapter: where a ref stands on the remote, whether one commit
    # contains another, and moving a branch or a tag forward.
    #
    # It is mixed into `Git`, which supplies `capture`. Every name that reaches a command is
    # checked first, and a push is never forced except for a tag the ancestry test has already
    # allowed to move.
    module GitRefs
      # A branch or tag name, or a commit, as git accepts one in a refspec: no space, no option, no
      # colon, and no `..`, so a name cannot smuggle a second ref or a flag into a command.
      REF_PATTERN = %r{\A[0-9A-Za-z_][0-9A-Za-z_./-]*\z}

      # Where a ref points on the remote, after fetching it.
      #
      # @param ref [String] a branch name, `refs/heads/<name>` or `refs/tags/<name>`
      # @param remote [String] the remote to ask
      # @param chdir [String, nil] a directory inside the repository
      # @return [String, nil] the commit the ref names, or nil when the remote has no such ref
      # @raise [ConsoleCapture::Failure] when the ref is malformed or the remote cannot be reached
      def remote_head(ref, remote: "origin", chdir: nil)
        name = checked_ref(ref)
        listed = capture("ls-remote", remote, name, chdir: chdir)
        refuse("git ls-remote #{remote} #{name} failed", listed) unless listed.ok?

        listed.out.lines.map { |line| line.split.first }.first
      end

      # Whether one commit is an ancestor of another, so that moving a ref from the first to the
      # second is a fast-forward. A commit is its own ancestor.
      #
      # @param ancestor [String] a commit
      # @param descendant [String] a commit
      # @param chdir [String, nil] a directory inside the repository
      # @return [Boolean] whether `descendant` contains `ancestor`
      # @raise [ConsoleCapture::Failure] when git cannot tell (an unknown commit, a malformed name)
      def ancestor?(ancestor, descendant, chdir: nil)
        result = capture("merge-base", "--is-ancestor", checked_ref(ancestor), checked_ref(descendant), chdir: chdir)
        return true if result.ok?
        return false if result.status.exitstatus == 1

        refuse("git merge-base failed", result)
      end

      # When the oldest commit of a range was made: the commits `newer` has that `older` lacks.
      #
      # @param older [String, nil] a commit, branch or ref, or nil for every commit of `newer`
      # @param newer [String] a commit, branch or ref
      # @param chdir [String, nil] a directory inside the repository
      # @return [Integer, nil] the oldest such commit's time, in seconds since the epoch, or nil
      #   when `newer` holds nothing `older` lacks
      # @raise [ConsoleCapture::Failure] when git cannot read the range
      def oldest_commit_time(older, newer, chdir: nil)
        range = older ? "#{checked_ref(older)}..#{checked_ref(newer)}" : checked_ref(newer)
        listed = capture("log", "--reverse", "--format=%ct", range, chdir: chdir)
        refuse("git log #{range} failed", listed) unless listed.ok?

        listed.out.lines.first&.to_i
      end

      # Moves a remote branch to a commit, and only forward: the push is refused by the remote when
      # the commit does not contain the branch's head, and is never forced.
      #
      # @param commit [String] the commit to push
      # @param branch [String] the branch to move
      # @param remote [String] the remote to push to
      # @param chdir [String, nil] a directory inside the repository
      # @return [void]
      # @raise [ConsoleCapture::Failure] when the remote refuses (not a fast-forward, a ruleset)
      def fast_forward(commit, branch, remote: "origin", chdir: nil)
        pushed = capture("push", remote, "#{checked_ref(commit)}:refs/heads/#{checked_ref(branch)}", chdir: chdir)
        refuse("git push #{remote} #{branch} was refused", pushed) unless pushed.ok?
      end

      # Moves a tag to a commit on the remote, and only forward: a tag that points at a commit the
      # new one does not contain is left where it is. A tag that does not yet exist is made.
      #
      # @param tag [String] the tag to move
      # @param commit [String] the commit it should name
      # @param remote [String] the remote to push to
      # @param chdir [String, nil] a directory inside the repository
      # @return [Symbol] `:created`, `:moved` or `:current`
      # @raise [ConsoleCapture::Failure] when the tag stands on a commit that is not an ancestor of
      #   `commit`, or the remote refuses
      def move_tag(tag, commit, remote: "origin", chdir: nil)
        name = checked_ref(tag)
        sha = checked_ref(commit)
        standing = remote_head("refs/tags/#{name}", remote: remote, chdir: chdir)
        return :current if standing == sha

        refuse_rewind(name, standing, sha) if standing && !ancestor?(standing, sha, chdir: chdir)
        force_tag(name, sha, remote, chdir)
        standing ? :moved : :created
      end

      private

      def force_tag(name, sha, remote, chdir)
        pushed = capture("push", "--force", remote, "#{sha}:refs/tags/#{name}", chdir: chdir)
        refuse("git push #{remote} #{name} was refused", pushed) unless pushed.ok?
      end

      def refuse_rewind(name, standing, sha)
        raise ConsoleCapture::Failure, "#{name} stands on #{standing[0, 7]}, which #{sha[0, 7]} does not contain"
      end

      def refuse(what, result)
        raise ConsoleCapture::Failure, "#{what}: #{result.err.strip}"
      end

      def checked_ref(ref)
        name = ref.to_s
        return name if name.match?(REF_PATTERN) && !name.include?("..")

        raise ConsoleCapture::Failure, "#{name.inspect} is not a ref name git can be given safely"
      end
    end
  end
end
