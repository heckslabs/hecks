# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "hecks/ci_speed/adapters/local_runner/refused"

module Hecks
  module Adapters
    class LocalRunner
      # Two temporary, detached git worktrees of a repository, one for each side of an experiment.
      # They live in a directory made for the run and are removed when the run ends, whatever
      # ended it. The repository's own checkout is only asked about its refs and its generated
      # tree, and is never written.
      class Checkouts
        # Where the generated Rust lives in a checkout, and what a cold checkout lacks.
        GENERATED_TREE = "rust/src/generated"

        # Makes both checkouts, yields their paths, and removes them afterwards.
        #
        # @param root [String] the repository whose worktrees these are
        # @param shas [Hash{Symbol => String}] the commit each side is checked out at, by side
        # @param scratch [String, nil] a directory to make the run's directory in; the system's
        #   temporary directory when nil
        # @yield [paths] the checkouts
        # @yieldparam paths [Hash{Symbol => String}] each side's checkout path, by side
        # @return [Object] what the block answers
        def self.with(root:, shas:, scratch: nil)
          FileUtils.mkdir_p(scratch) if scratch
          directory = Dir.mktmpdir("ci-experiment-", scratch)
          checkouts = new(root, directory)
          yield shas.to_h { |side, sha| [side, checkouts.add(side, sha)] }
        ensure
          checkouts&.remove_all
          FileUtils.remove_entry(directory) if directory && File.exist?(directory)
        end

        # @param root [String] the repository
        # @param directory [String] where the checkouts are made
        def initialize(root, directory)
          @root = root
          @directory = directory
          @added = []
        end

        # @param side [Symbol] which side the checkout is for
        # @param sha [String] the commit to check out, detached
        # @return [String] the checkout's path
        # @raise [Refused] when git cannot make the worktree
        def add(side, sha)
          path = File.join(@directory, side.to_s)
          @added << path
          git("worktree", "add", "--detach", path, sha)
          path
        end

        # Removes every checkout made, and forgets any whose creation stopped half way.
        #
        # @return [void]
        def remove_all
          @added.each { |path| Open3.capture2e("git", "-C", @root, "worktree", "remove", "--force", path) }
          Open3.capture2e("git", "-C", @root, "worktree", "prune")
        end

        # Puts a checkout's generated tree back to what a sample starts from: nothing, or a copy of
        # the tree the asking checkout holds.
        #
        # @param checkout [String] a checkout's path
        # @param copy_from [String, nil] the repository whose generated tree is copied in; nil
        #   leaves the checkout with none
        # @return [void]
        def self.reset_generated_tree(checkout, copy_from)
          target = File.join(checkout, GENERATED_TREE)
          FileUtils.rm_rf(target)
          FileUtils.cp_r(File.join(copy_from, GENERATED_TREE), target) if copy_from
        end

        private

        def git(*words)
          out, status = Open3.capture2e("git", "-C", @root, *words)
          raise Refused, "git #{words.join(" ")} failed in #{@root}: #{out.strip}" unless status.success?

          out
        end
      end
    end
  end
end
