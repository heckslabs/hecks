# frozen_string_literal: true

require "tmpdir"
require_relative "../git"
require_relative "../console_capture"

module Hecks
  module Adapters
    class MainIntegration
      # The checkout a run landed in, as an integration step reads it: where local main and
      # origin/main stand, what a range changed and says, and a clean detached copy of a commit.
      class Repository
        # The prefix of the scratch directory a clean copy is made in.
        COPY_PREFIX = "hecks-main-integration"

        # The files a development checkout keeps for itself and a clean copy must not hold.
        LOCAL_FILES = "lib/**/*.local.{hecksagon,world}"

        # @param checkout [String] a directory inside the repository
        def initialize(checkout)
          @checkout = checkout
          @git = Git.new
        end

        # @param ref [String] a branch or commit
        # @return [String, nil] the full commit it names, nil when it names none
        def commit(ref)
          done = @git.capture("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: @checkout)
          done.ok? ? done.out.strip : nil
        end

        # @return [String] the commit local main is at
        # @raise [ConsoleCapture::Failure] when the checkout has no main
        def main = commit("main") || raise(ConsoleCapture::Failure, "#{@checkout} has no main branch")

        # @return [String] the commit origin/main is at, as last fetched; main's when none is
        def remote_main = commit("origin/main") || main

        # @param base [String] the commit the range starts after
        # @param tip [String] the commit it ends at
        # @return [Array<String>] the paths the range changed
        def changed(base, tip) = read("diff", "--name-only", base, tip).split("\n").reject(&:empty?)

        # @return [Array<String>] the message of every commit in the range
        def messages(base, tip) = read("log", "--format=%B%x1e", "#{base}..#{tip}").split("\x1e").map(&:strip)

        # Yields a clean detached copy of a commit, holding only what the commit tracks, and
        # removes it once the block ends.
        #
        # @param tip [String] the commit to copy
        # @yieldparam directory [String] the copy
        # @return [Object] what the block answered
        def clean_copy(tip)
          Dir.mktmpdir(COPY_PREFIX) do |scratch|
            directory = File.join(scratch, "main")
            read("worktree", "add", "--quiet", "--detach", directory, tip)
            begin
              yield refuse_local_files!(directory)
            ensure
              @git.capture("worktree", "remove", "--force", directory, chdir: @checkout)
            end
          end
        end

        private

        def refuse_local_files!(directory)
          found = Dir.glob(LOCAL_FILES, base: directory)
          raise ConsoleCapture::Failure, "the clean copy holds local files: #{found.join(", ")}" unless found.empty?

          directory
        end

        def read(*args)
          done = @git.capture(*args, chdir: @checkout)
          raise ConsoleCapture::Failure, "git #{args.first} in #{@checkout}: #{done.err.strip}" unless done.ok?

          done.out
        end
      end
    end
  end
end
