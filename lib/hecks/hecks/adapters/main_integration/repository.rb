# frozen_string_literal: true

require "digest"
require "fileutils"
require "hecks/cache_dir"
require_relative "../git"
require_relative "../console_capture"
require_relative "../bounded_capture"
require_relative "copy_lock"
require_relative "carried_check"
require_relative "boarded_check"

module Hecks
  module Adapters
    class MainIntegration
      # The checkout a run landed in, as an integration step reads it: where local main and
      # origin/main stand, what a range changed and says, and a clean detached copy of a commit.
      class Repository
        # The cache directory, under `Hecks::CacheDir`, that each checkout's clean copy is made in.
        COPY_PREFIX = "main-integration"

        # The lock file's name in the repository's git directory.
        LOCK = "hecks-main-integration.lock"

        # The files a development checkout keeps for itself and a clean copy must not hold.
        LOCAL_FILES = "lib/**/*.local.{hecksagon,world}"

        # @return [String] the checkout the repository is read in
        attr_reader :checkout

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

        # Fetches `origin`. A failed fetch leaves `origin/main` as it was: a stale one reads as
        # "not carried", so a run goes on to verify.
        #
        # @return [void]
        def refresh = @git.capture("fetch", "--quiet", "origin", chdir: @checkout)

        # @param landed [String] the commit a run landed
        # @return [String, nil] why `origin/main` (as fetched) holds it, or why an open train pull
        #   request does (`BoardedCheck`); nil when neither does
        def carried_by(landed) = CarriedCheck.new(@checkout).by(landed) || BoardedCheck.new(@checkout).by(landed)

        # @param base [String] the commit the range starts after
        # @param tip [String] the commit it ends at
        # @return [Array<String>] the paths the range changed
        def changed(base, tip) = read("diff", "--name-only", base, tip).split("\n").reject(&:empty?)

        # @return [Array<String>] the message of every commit in the range
        def messages(base, tip) = read("log", "--format=%B%x1e", "#{base}..#{tip}").split("\x1e").map(&:strip)

        # Yields a clean detached copy of a commit, holding only what the commit tracks, and
        # removes it once the block ends. The copy sits at one path for this checkout, under the
        # cache directory, so a Rust build keyed by the copy's path (a binary build's slot) finds
        # the last copy's output; verifications take turns at it (`CopyLock`), waiting at most the
        # world's `spec_bounds` `check_seconds`. A copy a crash left behind is removed first.
        #
        # @param tip [String] the commit to copy
        # @yieldparam directory [String] the copy
        # @return [Object] what the block answered
        # @raise [ConsoleCapture::Failure] when another verification holds the turn past the wait
        def clean_copy(tip, &)
          CopyLock.hold(lock_file, wait: BoundedCapture.seconds(@checkout, :check_seconds)) do
            directory = File.join(scratch, "main")
            discard(directory)
            read("worktree", "add", "--quiet", "--detach", directory, tip)
            in_copy(directory, &)
          end
        end

        # @return [String] the directory this checkout's copies are made in: its name and a digest
        #   of its path, so two checkouts never share one
        def scratch
          real = File.realpath(@checkout)
          CacheDir.path(File.join(COPY_PREFIX, "#{File.basename(real)}-#{Digest::SHA256.hexdigest(real)[0, 8]}"))
        end

        # @return [String] the lock file of the turn at the copy, in the repository's git
        #   directory, so it goes when the repository does
        def lock_file = File.join(read("rev-parse", "--path-format=absolute", "--git-common-dir").strip, LOCK)

        private

        def in_copy(directory)
          yield refuse_local_files!(directory)
        ensure
          discard(directory)
          Dir.rmdir(scratch) if Dir.exist?(scratch) && Dir.empty?(scratch)
        end

        def discard(directory)
          @git.capture("worktree", "remove", "--force", directory, chdir: @checkout) if File.exist?(directory)
          FileUtils.rm_rf(directory)
          @git.capture("worktree", "prune", chdir: @checkout)
        end

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
