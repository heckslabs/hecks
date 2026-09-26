require "open3"
require "tmpdir"

module Hecks
  module Vendoring
    # A local git repository read through the `git` executable, never through
    # its working tree.
    #
    # Everything here names a commit and reads what that commit holds, so a
    # shared checkout with uncommitted edits, or a different branch checked
    # out, cannot leak into what gets vendored.
    class GitSource
      # @param path [String] a directory that is a git repository (or a
      #   worktree of one)
      # @raise [Vendoring::Error] if `path` is not a directory
      def initialize(path)
        @path = File.expand_path(path.to_s)
        raise Error, "no source repository at #{@path}" unless File.directory?(@path)
      end

      # @return [String] the absolute path of the repository
      attr_reader :path

      # Resolves a commit-ish to the full commit id it names.
      #
      # @param ref [String] a branch, tag, abbreviated or full commit id
      # @return [String] the 40-character commit id
      # @raise [Vendoring::Error] if `ref` names no commit in the repository
      def commit(ref)
        out, _err, status = git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
        raise Error, "no commit #{ref.inspect} in #{@path}" unless status.success?

        out.strip
      end

      # Lists tag names matching a shell pattern.
      #
      # @param pattern [String] a `git tag --list` pattern, such as `"payments-v*"`
      # @return [Array<String>] the matching tag names, in git's own order
      def tags(pattern)
        out, _err, status = git("tag", "--list", pattern)
        status.success? ? out.lines.map(&:chomp) : []
      end

      # Reads one file as a commit holds it.
      #
      # @param ref [String] the commit-ish to read from
      # @param file [String] a repository-relative path
      # @return [String, nil] the file's content, or nil when the commit has no such file
      def read(ref, file)
        out, _err, status = git("show", "#{ref}:#{file}")
        status.success? ? out : nil
      end

      # Lists the files directly inside a directory of a commit.
      #
      # Subdirectories are left out on purpose: a vendored package carries the
      # top-level files of its subtree and nothing nested beneath.
      #
      # @param ref [String] the commit-ish to read from
      # @param subtree [String] a repository-relative directory, such as `"payments/bluebook"`
      # @param glob [String] a `File.fnmatch` pattern the file's own name must match
      # @return [Array<String>] repository-relative paths, sorted
      def files(ref, subtree, glob = "*")
        out, _err, status = git("ls-tree", "-r", "--name-only", ref, "--", subtree)
        return [] unless status.success?

        out.lines.map(&:chomp).select do |file|
          File.dirname(file) == subtree && File.fnmatch(glob, File.basename(file))
        end.sort
      end

      # Extracts named files of a commit into a directory with `git archive`,
      # keeping their repository-relative paths.
      #
      # @param ref [String] the commit-ish to export
      # @param files [Array<String>] repository-relative paths to export
      # @param into [String] an existing directory to extract into
      # @return [void]
      # @raise [Vendoring::Error] if `git archive` or `tar` fails
      def export(ref, files, into)
        Dir.mktmpdir("hecks-archive") do |scratch|
          tarball = File.join(scratch, "export.tar")
          run!("git archive", "git", "-C", @path, "archive", "--format=tar", "--output=#{tarball}", ref, "--", *files)
          run!("tar", "tar", "-xf", tarball, "-C", into)
        end
      end

      private

      def git(*) = Open3.capture3("git", "-C", @path, *)

      def run!(label, *command)
        _out, err, status = Open3.capture3(*command)
        raise Error, "#{label} failed: #{err.lines.first.to_s.strip}" unless status.success?
      end
    end
  end
end
