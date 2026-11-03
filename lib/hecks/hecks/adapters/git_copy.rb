# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "git_names"
require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `Copying` port's adapter for `TreeCopy`: writes the tree, or one path of it, as it
    # stood at a ref into a directory that is new or empty, so old code can be read or built
    # without a branch, a worktree or a raw `git archive`.
    #
    # It reads the repository's objects and writes only into the destination. A destination
    # inside the checkout, a relative one, or one that already holds files is declined, and so
    # is a ref or path git could read as an option.
    class GitCopy
      include GitNames
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Copies a tree at a ref into a new directory.
      #
      # @param held [Hash] the `TreeCopy` record: `checkout` (a directory inside the repository; the
      #   current directory when absent), `ref`, `path` (from the repository's top level; the whole
      #   tree when absent) and `destination` (an absolute path)
      # @return [Hash{Symbol => Hash}] `report:` what was copied and where
      # @raise [ConsoleCapture::Failure] on a ref, path or destination it refuses, or when git or
      #   `tar` fails
      def copy(**held)
        settle(held)
        revision = checked_revision(plain(held[:ref]))
        path = checked_path(plain(held[:path]))
        target = clear_destination(plain(held[:destination]))
        commit = read("rev-parse", "--short", "#{revision}^{commit}")
        files = extract(revision, path, target)
        { report: { value: "copied #{files} files of #{path.empty? ? "the top level" : path} at #{commit} into #{target}" } }
      end

      private

      # The destination as an absolute path, once it is known to be somewhere a copy may go.
      def clear_destination(destination)
        text = destination.to_s
        raise ConsoleCapture::Failure, "#{text.inspect} is not an absolute path" unless text.start_with?("/")

        target = File.expand_path(text)
        if target == @checkout || target.start_with?("#{@checkout}/")
          raise ConsoleCapture::Failure, "#{target} is inside the checkout, which a copy never writes to"
        end
        return target unless File.exist?(target) && !(File.directory?(target) && Dir.empty?(target))

        raise ConsoleCapture::Failure, "#{target} already holds files"
      end

      # Archives the tree to a temporary tar file, then unpacks it into the destination.
      def extract(revision, path, target)
        Dir.mktmpdir("hecks-tree-copy") do |scratch|
          tarball = File.join(scratch, "tree.tar")
          read("archive", "--format=tar", "--output=#{tarball}", revision, *(path.empty? ? [] : ["--", path]))
          FileUtils.mkdir_p(target)
          out, status = Open3.capture2e("tar", "-xf", tarball, "-C", target)
          raise ConsoleCapture::Failure, "tar failed: #{out.strip}" unless status.success?
        end
        Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).count { |entry| File.file?(entry) }
      end
    end
  end
end
