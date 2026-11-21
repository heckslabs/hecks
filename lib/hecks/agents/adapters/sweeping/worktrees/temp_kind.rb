# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      class Worktrees
        # Says whether a branchless worktree is a temp one: it sits under a temp root and its
        # `HEAD` in the worktree's own directory has not moved for the idle window. Both sides of
        # the path compare after `File.realpath`, since the worktree list gives `/private/var/...`
        # for `/var/...`.
        class TempKind
          GITDIR_PREFIX = /\Agitdir:\s*/

          # @param roots [Array<String>] the temp directories
          # @param idle [Numeric] seconds a worktree's `HEAD` must have stood still
          # @param clock [#call] returns the current time
          def initialize(roots:, idle:, clock: -> { Time.now })
            @roots = roots.filter_map { |root| real(root) }
            @idle = idle
            @clock = clock
          end

          # @param path [String] a worktree's directory
          # @return [Boolean] true when it is under a temp root and idle for the window
          def temp?(path)
            under?(path) && idle?(path)
          end

          private

          def under?(path)
            full = real(path)
            !full.nil? && @roots.any? { |root| full.start_with?("#{root}/") }
          end

          def idle?(path)
            head = File.join(gitdir(path), "HEAD")
            @clock.call - File.mtime(head) >= @idle
          rescue SystemCallError
            false
          end

          def gitdir(path)
            File.read(File.join(path, ".git")).sub(GITDIR_PREFIX, "").strip
          end

          def real(path)
            File.realpath(path)
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
