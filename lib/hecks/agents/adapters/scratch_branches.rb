# frozen_string_literal: true

require "open3"
require "hecks/hecks/adapters/main_launcher"

module Hecks
  module Adapters
    # The `ScratchBranches` port's adapter for `Canary`: cuts a canary's scratch branch from its
    # base in the main checkout with `LinkedTree.add!`, applies the patch there and commits it.
    # It never pushes and judges nothing: when a canary is planted and what its verdict means are
    # the bluebook's. Git runs with an argument list, never a shell.
    #
    # A patch that does not apply is refused with a reason that begins "the patch does not apply",
    # and its empty worktree is retired with `Landing.retire!`, since main holds its tip.
    class ScratchBranches
      # The branch could not be cut or the patch committed; the message says why.
      class Uncut < StandardError; end

      # How every refusal of the patch itself begins, so the bluebook tells it from a passing fault.
      PATCH_REFUSED = "the patch does not apply"

      # @param run [#call, nil] stand-in: takes the argv, an optional `stdin`, and `chdir`, answers
      #   `[stdout, stderr, status]`
      # @param root [String, nil] the main checkout, where the launcher and its worktrees live
      def initialize(run: nil, root: nil)
        @run = run || ->(argv, stdin: "", chdir: nil) { Open3.capture3(*argv, stdin_data: stdin, chdir: chdir) }
        @root = root || MainLauncher.main_root(MainLauncher::CHECKOUT)
      end

      # @param asked [Hash] the `CutScratch` ask: `base:` the ref the branch is cut from, `patch:`
      #   the known-bad diff, `branch:` the canary's branch name (the round is appended),
      #   `message:` the scratch commit's message, `round:` how often the canary was planted before
      # @return [Hash{Symbol => Hash}] `submission:` the scratch commit, `checkout:` its worktree
      #   and `branch:` the branch cut
      # @raise [Uncut] naming why the branch could not be cut or the patch committed
      def cut_scratch(**asked)
        name = "#{plain(asked[:branch])}-#{plain(asked[:round]).to_i + 1}"
        path = File.join(@root, ".claude", "worktrees", name)
        cut(name, path, plain(asked[:base]))
        commit(name, path, plain(asked[:patch]), plain(asked[:message]))
        { submission: { value: tip(path) }, checkout: { value: path }, branch: { value: name } }
      end

      private

      def cut(name, path, base)
        launch("LinkedTree.add!", "branch.value=#{name}", "base.value=#{base}", "path.value=#{path}")
        raise Uncut, "LinkedTree.add! opened no worktree at #{path}" unless File.directory?(path)
      end

      def commit(name, path, patch, message)
        _out, err, status = @run.call(["git", "-C", path, "apply", "--index", "-"], stdin: patch)
        unless status.success?
          launch("Landing.retire!", "branch.value=#{name}", "checkout.value=#{path}", "--confirm")
          raise Uncut, "#{PATCH_REFUSED} to its base: #{err.strip}"
        end
        git(path, "commit", "-m", message)
      end

      def tip(path) = git(path, "rev-parse", "HEAD").strip

      def git(path, *args)
        out, err, status = @run.call(["git", "-C", path, *args])
        raise Uncut, "git #{args.first} failed in #{path}: #{err.strip}" unless status.success?

        out
      end

      def launch(*args)
        launcher = MainLauncher.path(@root) or raise Uncut, "no launcher in #{@root}"
        _out, err, status = @run.call([launcher, *args, "--wait"], chdir: @root)
        raise Uncut, "#{args.first} refused: #{err.strip.lines.last}" unless status.success?
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
