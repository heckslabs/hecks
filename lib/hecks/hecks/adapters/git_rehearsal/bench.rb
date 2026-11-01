# frozen_string_literal: true

require "tmpdir"
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
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param commit [String] the commit to check out
        # @yieldparam directory [String] the copy
        # @return [Object] what the block returned
        def rehearse(commit)
          Dir.mktmpdir("hecks-push-rehearsal") do |scratch|
            directory = File.join(scratch, "bench")
            read("worktree", "add", "--quiet", "--detach", directory, commit)
            begin
              yield directory
            ensure
              @git.capture("worktree", "remove", "--force", directory, chdir: @checkout)
            end
          end
        end
      end
    end
  end
end
