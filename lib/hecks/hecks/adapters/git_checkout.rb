# frozen_string_literal: true

require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `Reading` port's adapter for `Checkout`: answers what state a checkout is in, as text,
    # so nothing needs a raw `git status`, `git diff` or `git log`. It reads and never writes.
    #
    # Every query takes `checkout`, a directory inside the repository (the current directory when
    # absent), and answers `text:`; a refusal is a `Runtime::NotFound`.
    class GitCheckout
      include GitWorktrees

      # How many commits `log` prints when it is given no range.
      RECENT = 20

      # A commit range as git writes one: names joined by `..` or `...`, never an option.
      RANGE = %r{\A[0-9A-Za-z_][0-9A-Za-z_./^~@{}-]*\z}

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # The branch, whether the checkout is a linked worktree, where it stands against local
      # `main` and `origin/main`, and each changed or untracked path.
      #
      # @param held [Hash] `checkout`
      # @return [Hash{Symbol => String}] `text:` one `name: value` line each, then the paths
      # @raise [Runtime::NotFound] when the checkout is not a repository
      def status(**held)
        answering(held) do
          lines = ["branch: #{read("rev-parse", "--abbrev-ref", "HEAD")}", "head: #{short(read("rev-parse", "HEAD"))}",
                   "worktree: #{linked? ? "linked" : "primary"} (#{@checkout})",
                   standing("main"), standing("origin/main")].compact
          changed = dirty
          lines << (changed.empty? ? "clean" : "changed:") << changed.map { |line| "  #{line}" }
          lines.flatten.join("\n")
        end
      end

      # What a checkout changed since a ref: the diffstat, or the paths alone.
      #
      # @param held [Hash] `checkout`; `since` (a ref, default `main`); `names_only` (true for the
      #   paths alone, not the diffstat)
      # @return [Hash{Symbol => String}] `text:` the diffstat, or one path per line
      # @raise [Runtime::NotFound] when the checkout or the ref is not found
      def changes(**held)
        answering(held) do
          since = ref(plain(held[:since]) || "main")
          flag = plain(held[:names_only]).to_s == "true" ? "--name-only" : "--stat"
          read("diff", flag, read("merge-base", since, "HEAD"))
        end
      end

      # The commits in a range, newest first, one `short-sha subject` line each.
      #
      # @param held [Hash] `checkout`; `range` (default: the last 20 commits)
      # @return [Hash{Symbol => String}] `text:` the commits
      # @raise [Runtime::NotFound] when the checkout or the range is not found
      def log(**held)
        answering(held) do
          range = plain(held[:range])
          read("log", "--format=%h %s", *(range ? [checked_range(range)] : ["-n", RECENT.to_s]))
        end
      end

      private

      def answering(held)
        settle(held)
        { text: "#{yield}\n" }
      rescue ConsoleCapture::Failure => e
        raise Runtime::NotFound, e.message
      end

      def linked? = primary.path != @checkout

      # How far `HEAD` is ahead of and behind a ref, or nil when the repository has no such ref.
      def standing(other)
        return nil unless @git.capture("rev-parse", "--verify", "--quiet", other, chdir: @checkout).ok?

        behind, ahead = read("rev-list", "--left-right", "--count", "#{other}...HEAD").split.map(&:to_i)
        "#{other}: ahead #{ahead}, behind #{behind}"
      end

      def checked_range(range)
        return range if range.match?(RANGE)

        raise ConsoleCapture::Failure, "#{range.inspect} is not a commit range"
      end
    end
  end
end
