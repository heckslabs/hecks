# frozen_string_literal: true

require_relative "git_names"
require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `Reading` port's adapter for `Checkout`: answers what state a checkout is in, as text,
    # so nothing needs a raw `git status`, `git diff` or `git log`. It reads and never writes.
    #
    # Every query takes `checkout`, a directory inside the repository (the current directory when
    # absent), and answers `text:`; a refusal is a `Runtime::NotFound`.
    class GitCheckout
      include GitNames
      include GitWorktrees

      # How many commits `log` prints when it is given no range.
      RECENT = 20

      # How many characters `show` returns before it cuts a file and says so.
      SHOWN = 200_000

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
      # @param held [Hash] `checkout`; `range` (default: the last 20 commits); `containing` (only
      #   the commits that add or remove this text); `path` (only the commits that touch it)
      # @return [Hash{Symbol => String}] `text:` the commits
      # @raise [Runtime::NotFound] when the checkout, the range or the path is not found
      def history(**held)
        answering(held) do
          range = plain(held[:range])
          read("log", "--format=%h %s", *containing(plain(held[:containing])),
               *(range ? [checked_range(range)] : ["-n", RECENT.to_s]), *within(plain(held[:path])))
        end
      end

      # A file as it stood at a ref, read from the repository's objects; nothing is checked out.
      # A file longer than `SHOWN` characters is cut and the text ends with a line saying so.
      #
      # @param held [Hash] `checkout`; `ref` (a commit, branch, tag or `sha^`); `path` (from the
      #   repository's top level, never starting with `/`, `-` or `.`-then-`/`, never holding `..`;
      #   the top level itself when absent)
      # @return [Hash{Symbol => String}] `text:` the file, exactly as committed
      # @raise [Runtime::NotFound] when the checkout, the ref or the path is not found
      def show(**held)
        settle(held)
        result = @git.capture("show", "#{checked_revision(plain(held[:ref]))}:#{checked_path(plain(held[:path]))}",
                              chdir: @checkout)
        raise ConsoleCapture::Failure, "git show failed in #{@checkout}: #{result.err.strip}" unless result.ok?

        { text: clipped(result.out) }
      rescue ConsoleCapture::Failure => e
        raise Runtime::NotFound, e.message
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

      # The pickaxe argument for the commits that add or remove `text`, none when no text is named.
      def containing(text)
        return [] if text.nil?
        raise ConsoleCapture::Failure, "#{text.inspect} is not text to look for" if text.empty? || text.match?(NOT_ONE_LINE)

        ["-S#{text}"]
      end

      # The pathspec that limits a log to one path, none when no path is named.
      def within(path)
        path.nil? ? [] : ["--", checked_path(path)]
      end

      def clipped(text)
        text = text.dup.force_encoding(Encoding::UTF_8).scrub
        return text if text.length <= SHOWN

        "#{text[0, SHOWN]}\n[cut at #{SHOWN} of #{text.length} characters]\n"
      end
    end
  end
end
