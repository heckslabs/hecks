# frozen_string_literal: true

require_relative "../git_worktrees"
require_relative "carried"

module Hecks
  module Adapters
    class GitLanding
      # What a landing leaves behind: the linked worktree it landed from and that worktree's branch.
      #
      # When in doubt it keeps both. It removes them only when the worktree is a linked one that
      # nobody stands in, holds no file that is not tracked and clean (ignored files and build
      # output count, so a local `.env` is never lost), and its branch tip, verified once, is
      # contained in local `onto` or every commit it adds has a patch-equivalent there (a rebase or
      # a cherry-pick carries a commit under another id). The worktree goes without `--force`, and
      # the branch goes only while it still names the verified tip, so a commit made in between is
      # never dropped.
      # `main`, `stable`, `edge`, the target and a branch another worktree holds are never deleted.
      class Tidy
        include GitWorktrees
        include Carried

        # Branches no tidy deletes, whatever they contain.
        PROTECTED = %w[main stable edge].freeze

        # The most paths a refusal names.
        NAMED = 5

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the landed branch
        # @param onto [String] the branch it was landed on
        # @param mode [Symbol] `:land` tidies after a landing, `:retire` removes the worktree named
        #   by `checkout`, `:discard` does that although `onto` lacks the branch's commits; every
        #   other guard holds, and the sentence names the tip it was at
        def initialize(git, checkout, branch:, onto:, mode: :land)
          @git = git
          @checkout = checkout
          @from = checkout
          @branch = ref(branch)
          @onto = ref(onto)
          @retiring = mode != :land
          @discarding = mode == :discard
        end

        # @return [String] a sentence saying what was removed, or why nothing was
        def call
          kept, said = retire
          kept ? "kept #{@branch}: #{said}" : said
        end

        # @return [Array(Boolean, String)] whether everything was kept, and the sentence saying so
        #   or what was removed
        def retire
          @checkout = primary.path
          tree = worktree_on(@branch)
          tip = tree && branch_tip(@branch)
          why = reason_to_keep(tree, tip)
          return [true, why] if why

          note = discarded_note(tip)
          kept, said = drop(tree.path, tip)
          [kept, kept || !@discarding ? said : "#{said}; #{note}"]
        end

        # What `retire` would do, said and not done: it removes nothing and takes no lock.
        #
        # @return [String] "would retire it", or "would keep it: " and why
        def verdict
          @checkout = primary.path
          tree = worktree_on(@branch)
          why = reason_to_keep(tree, tree && branch_tip(@branch))
          why ? "would keep it: #{why}" : "would retire it"
        end

        private

        def reason_to_keep(tree, tip)
          return "no linked worktree has it checked out" unless tree

          refusal_for_tree(tree) || unsaved(tree.path) || unmerged(tip)
        rescue SystemCallError, ConsoleCapture::Failure => e
          "#{tree&.path || @branch} could not be checked (#{e.message}), so nothing was removed"
        end

        def refusal_for_tree(tree)
          return "its worktree is the main checkout" if same?(tree.path, primary.path)
          return "#{@branch} is protected" if protected_branch?
          return "#{tree.path} is not the worktree named #{@from}" if @retiring && !same?(tree.path, @from)

          "#{tree.path} is where this runs: run from the main checkout to retire it" if standing_in?(tree.path)
        end

        def protected_branch? = PROTECTED.include?(@branch) || @branch == @onto

        def unsaved(path)
          found = status_lines(path)
          return if found.empty?

          "#{path} holds uncommitted work or files that are not tracked and clean: #{named(found)}"
        end

        def status_lines(path)
          out = read("status", "--porcelain", "--ignored", "--untracked-files=all", dir: path)
          out.lines.map(&:rstrip).reject(&:empty?)
        end

        def named(lines)
          shown = lines.first(NAMED).join(", ")
          lines.size > NAMED ? "#{shown} and #{lines.size - NAMED} more" : shown
        end

        def drop(path, tip)
          return [true, "#{@branch} moved after it was checked"] unless branch_tip(@branch) == tip

          read("worktree", "remove", path, dir: @checkout)
          [false, delete_branch(path, tip)]
        rescue ConsoleCapture::Failure => e
          [true, "git would not remove #{path}: #{e.message}"]
        end

        def delete_branch(path, tip)
          return "removed #{path}; kept #{@branch}, which another worktree holds" if worktree_on(@branch)

          read("update-ref", "-d", "refs/heads/#{@branch}", tip, dir: @checkout)
          "removed #{path} and deleted #{@branch}"
        rescue ConsoleCapture::Failure
          "removed #{path}; kept #{@branch}, which moved after it was verified"
        end

        def same?(one, other) = File.identical?(one, other)

        # Whether the directory the process stands in, or the landing's checkout, is in the tree.
        def standing_in?(path)
          [here, (@from unless @retiring)].compact.any? { |dir| inside?(path, dir) }
        end

        def here
          Dir.pwd
        rescue SystemCallError
          nil
        end

        def inside?(tree, dir)
          current = File.realpath(dir)
          loop do
            return true if File.identical?(current, tree)

            above = File.dirname(current)
            return false if above == current

            current = above
          end
        rescue SystemCallError
          false
        end
      end
    end
  end
end
