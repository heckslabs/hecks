# frozen_string_literal: true

require "fileutils"
require "find"
require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `FileRemoving` port's adapter for `Removal`: removes one path inside a checkout, so a session
    # that cannot run `rm` itself can still tidy its own worktree.
    #
    # It acts only inside the checkout named. The path is resolved before anything is removed: `..` and a
    # symlinked directory that leads out are refused, and a symlink itself is unlinked without touching what
    # it points at. It takes one path as given and never expands a pattern. It refuses the checkout itself,
    # `.git` (or anything under it), a directory unless the record says `directory`, a directory that holds
    # another checkout, and a file git tracks when the checkout is the primary one (a linked worktree may
    # remove its own tracked files; the branch records it).
    class GitFileRemoval
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Removes the path, then says what was removed.
      #
      # @param held [Hash] the `Removal` record: `checkout` (a directory inside the repository; the
      #   current directory when absent), `path` (relative to the checkout, or absolute inside it) and
      #   `directory` (true to remove a directory with what is in it)
      # @return [Hash{Symbol => Hash}] `path:` the path relative to the checkout, `report:` what was done
      # @raise [ConsoleCapture::Failure] naming the rule the path broke
      def delete(**held)
        root = File.realpath(settle(held))
        named = plain(held[:path]).to_s.strip
        raise ConsoleCapture::Failure, "no path named" if named.empty?

        target = resolve(root, named)
        relative = relative_to(root, target, named)
        refuse_dotgit(relative, named)
        refuse_kind(target, relative, plain(held[:directory]) == true)
        refuse_tracked(root, relative)
        FileUtils.rm_rf(target)
        { path: { value: relative }, report: { value: "removed #{relative} from #{root}" } }
      end

      private

      # The path with its parent's symlinks resolved, so a link that leads out of the checkout shows. The last
      # part is kept as written: a symlink there is removed itself, never followed.
      def resolve(root, named)
        lexical = File.expand_path(named, root)
        parent = File.dirname(lexical)
        raise ConsoleCapture::Failure, "#{named} is not inside #{root}: its directory does not exist" unless File.directory?(parent)

        File.join(File.realpath(parent), File.basename(lexical))
      end

      def relative_to(root, target, named)
        raise ConsoleCapture::Failure, "#{named} is the checkout itself, which is not removed" if target == root
        raise ConsoleCapture::Failure, "#{named} is not inside #{root}" unless target.start_with?("#{root}/")

        target.delete_prefix("#{root}/")
      end

      def refuse_dotgit(relative, named)
        return unless relative.split("/").include?(".git")

        raise ConsoleCapture::Failure, "#{named} is, or is inside, .git, which is not removed"
      end

      def refuse_kind(target, relative, directory)
        raise ConsoleCapture::Failure, "#{relative} does not exist" unless File.exist?(target) || File.symlink?(target)
        return if File.symlink?(target) || !File.directory?(target)
        raise ConsoleCapture::Failure, "#{relative} is a directory; say directory to remove it and what is in it" unless directory

        nested = Find.find(target).find { |found| File.basename(found) == ".git" }
        raise ConsoleCapture::Failure, "#{relative} holds another checkout (#{nested.delete_prefix("#{target}/")}), which is not removed" if nested
      end

      # A file git tracks stays in the primary checkout: removing it there changes main's own working tree.
      def refuse_tracked(root, relative)
        return unless File.realpath(primary.path) == root

        listed = @git.capture("--literal-pathspecs", "ls-files", "--", relative, chdir: root)
        raise ConsoleCapture::Failure, "git ls-files failed in #{root}: #{listed.err.strip}" unless listed.ok?
        return if listed.out.strip.empty?

        raise ConsoleCapture::Failure, "#{relative} is tracked in the primary checkout; remove it from a linked worktree"
      end
    end
  end
end
