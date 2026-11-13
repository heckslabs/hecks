module Hecks
  module Adapters
    # Says, once per process, when a linked worktree lacks the gitignored overlay files its main
    # checkout keeps and does not borrow them (WorktreeBorrow), as under the spec runner: a
    # command run there stores in Memory. This warns; it never blocks the command.
    module WorktreeOverlay
      # The line a linked worktree's `.git` file holds, naming the directory in the main checkout.
      GITDIR_LINE = /\Agitdir: (.+)\s*\z/

      # Where the overlay files live, relative to a checkout's root.
      OVERLAY_PATTERNS = ["lib/hecks/hecks/*.local.hecksagon", "lib/hecks/hecks/*.local.world",
                          "environments/local.hecksagon", "environments/local.world"].freeze

      module_function

      # Warns on standard error the first time a domain loads from a linked worktree that lacks
      # overlay files of its main checkout. Nothing is printed again in the same process.
      #
      # @param directory [String] the domain directory being loaded
      # @param err [#puts] where the warning goes
      # @return [String, nil] the warning printed, or nil when there was nothing to say
      def warn_once(directory, err: $stderr)
        return if @warned

        text = warning_for(directory)
        return unless text

        @warned = true
        err.puts(text)
        text
      end

      # The warning for a directory inside a linked worktree, or nil when none applies. It asks
      # what a boot with no named environment would lack, so a Memory boot beside it (the
      # resident loads one) says nothing about files a default boot borrows.
      #
      # @param directory [String] a directory inside a checkout
      # @param env [#to_h] the process environment
      # @return [String, nil]
      def warning_for(directory, env: ENV)
        _main, files = gap(directory, env: env.to_h.except("HECKS_ENVIRONMENT"))
        message(files)
      end

      # The main checkout a linked worktree was made from, and the overlay files that checkout
      # holds and this worktree lacks. Nothing is returned for a checkout that is not a worktree,
      # and nothing is missing while the worktree borrows the main checkout's (WorktreeBorrow).
      #
      # @param directory [String] a directory inside a checkout
      # @param env [#[]] where the borrow reads the spec switch and the environment
      # @return [Array(String, Array<String>), Array(nil, Array)] the main checkout's root, then the
      #   relative paths of the overlay files it holds and the worktree lacks
      def gap(directory, env: ENV)
        worktree = checkout_root(directory)
        main = worktree && main_checkout(worktree)
        return [nil, []] unless main
        return [main, []] if WorktreeBorrow.from(directory, env: env)

        [main, missing(overlay_files(main), overlay_files(worktree))]
      end

      # Relative paths of the overlay files that a checkout holds.
      #
      # @param root [String] a checkout's root
      # @return [Array<String>] sorted relative paths
      def overlay_files(root)
        OVERLAY_PATTERNS.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
                        .map { |path| path.delete_prefix("#{root}/") }
                        .sort
      end

      # The overlay files the main checkout holds and the worktree does not.
      #
      # @param main [Array<String>] relative paths in the main checkout
      # @param worktree [Array<String>] relative paths in the worktree
      # @return [Array<String>]
      def missing(main, worktree)
        main - worktree
      end

      # The one-line warning naming the files and the store they change.
      #
      # @param files [Array<String>] relative paths the worktree lacks
      # @return [String, nil] the warning, or nil when no file is missing
      def message(files)
        return if files.empty?

        "hecks: this worktree lacks #{files.join(", ")} from the main checkout; " \
          "bluebooks that use them store in Memory here, not in the main checkout's store; " \
          "a command that writes one is run in the main checkout (HECKS_NO_FORWARD=1 refuses it instead)"
      end

      # The root of the checkout a directory is in, and whether that checkout is a linked worktree.
      #
      # @param directory [String]
      # @return [String, nil] the root when it is a linked worktree, else nil
      def checkout_root(directory)
        root = ascend_to_git(File.expand_path(directory))
        root if root && File.file?(File.join(root, ".git"))
      end

      # The main checkout a linked worktree was made from, found through its `.git` file.
      #
      # @param worktree [String] a linked worktree's root
      # @return [String, nil]
      def main_checkout(worktree)
        gitdir = File.read(File.join(worktree, ".git"))[GITDIR_LINE, 1]
        return unless gitdir

        common = File.expand_path("../..", File.expand_path(gitdir, worktree))
        File.dirname(common)
      end

      # Walks up from a directory to the first one holding a `.git` entry.
      #
      # @param directory [String] an absolute path
      # @return [String, nil]
      def ascend_to_git(directory)
        root = Pathname.new(directory).ascend.find { |dir| dir.join(".git").exist? }
        root&.to_s
      end
    end
  end
end

require_relative "worktree_borrow"
