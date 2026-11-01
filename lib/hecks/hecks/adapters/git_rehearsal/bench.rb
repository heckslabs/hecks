# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "reading"

module Hecks
  module Adapters
    class GitRehearsal
      # A detached copy of a commit a rehearsal runs in, removed once it ends, so the stages check
      # the very commit a push would carry and not whatever a checkout holds.
      class Bench
        include Reading

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param scope [String] a scope sweeps and names only its own benches, so a quick rehearsal
        #   never removes the live bench of a full one
        def initialize(git, checkout, scope: "full")
          @git = git
          @checkout = checkout
          @scope = scope
        end

        # The prefix of the scratch directory every bench is made in, which tells a bench of this
        # adapter from any other worktree.
        PREFIX = "hecks-push-rehearsal"

        # The prefix of a `quick` rehearsal's bench.
        QUICK = "#{PREFIX}-quick".freeze

        # A worktree's line in `git worktree list --porcelain`.
        LISTED = /\Aworktree /

        # Removes benches an earlier rehearsal left registered (it was killed before it cleaned up):
        # only worktrees named `<tmp>/hecks-push-rehearsal*/bench`, so no other worktree is touched.
        # Call it only while no rehearsal runs, which the caller's lock ensures.
        #
        # @return [Integer] how many stale benches were removed
        def sweep
          stale = benches
          stale.each do |directory|
            @git.capture("worktree", "remove", "--force", directory, chdir: @checkout)
            FileUtils.rm_rf(File.dirname(directory))
          end
          @git.capture("worktree", "prune", chdir: @checkout) unless stale.empty?
          stale.size
        end

        # @param commit [String] the commit to check out
        # @yieldparam directory [String] the copy
        # @return [Object] what the block returned
        def rehearse(commit)
          Dir.mktmpdir(@scope == "quick" ? QUICK : PREFIX) do |scratch|
            directory = File.join(scratch, "bench")
            read("worktree", "add", "--quiet", "--detach", directory, commit)
            begin
              yield directory
            ensure
              @git.capture("worktree", "remove", "--force", directory, chdir: @checkout)
            end
          end
        end

        private

        # The registered worktrees that are benches of this adapter.
        def benches
          listed = read("worktree", "list", "--porcelain").lines.grep(LISTED)
          listed.map { |line| line.delete_prefix("worktree ").strip }.select { |directory| bench?(directory) }
        end

        def bench?(directory)
          return false unless File.basename(directory) == "bench"

          name = File.basename(File.dirname(directory))
          @scope == "quick" ? name.start_with?(QUICK) : (name.start_with?(PREFIX) && !name.start_with?(QUICK))
        end
      end
    end
  end
end
