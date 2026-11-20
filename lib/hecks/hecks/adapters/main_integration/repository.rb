# frozen_string_literal: true

require "digest"
require "fileutils"
require "hecks/cache_dir"
require_relative "../git"
require_relative "../checkout_gate"
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

        # The line `git revert` writes into its commit's message, naming the commit it undid.
        REVERTED = /^This reverts commit ([0-9a-f]{7,40})/

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

        # A hecks checkout's commit holds the hecks launcher; a project built on the hecks gem
        # (one that lands through the same Landing) does not, and has no main integration here.
        #
        # @param ref [String] a commit
        # @return [Boolean] whether the commit tracks the launcher (`CheckoutGate::LAUNCHER`)
        def launcher?(ref) = @git.capture("cat-file", "-e", "#{ref}:#{CheckoutGate::LAUNCHER}", chdir: @checkout).ok?

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

        # The landings in a range, read as facts: each first-parent merge commit with the paths it
        # changed against its first parent.
        #
        # @param base [String] the commit the range starts after
        # @param tip [String] the commit it ends at
        # @return [Array<Hash{Symbol => Object}>] oldest first: `sha:`, `subject:` and `paths:`
        def merges(base, tip)
          read("rev-list", "--first-parent", "--merges", "--reverse", "#{base}..#{tip}").lines.map do |line|
            sha = line.strip
            { sha: sha, subject: read("log", "-1", "--format=%s", sha).strip, paths: changed("#{sha}^1", sha) }
          end
        end

        # @return [Array<String>] the first-parent commits in the range that revert a landing
        def reverts(base, tip)
          read("log", "--first-parent", "--format=%H%x09%s", "#{base}..#{tip}").lines.filter_map do |line|
            sha, subject = line.chomp.split("\t", 2)
            sha if subject.to_s.start_with?("Revert \"Merge")
          end
        end

        # @return [Array<String>] the commits the range's first-parent reverts say they undid
        def reverted(base, tip) = read("log", "--first-parent", "--format=%B", "#{base}..#{tip}").scan(REVERTED).flatten

        # @param sha [String] a commit
        # @return [String, nil] its first parent, nil when it has none
        def first_parent(sha) = commit("#{sha}^1")

        # @param ref [String] a commit
        # @param path [String] a file's path from the repository's top level
        # @return [String, nil] the file as the commit holds it, nil when it holds none
        def file_at(ref, path) = @git.capture("show", "#{ref}:#{path}", chdir: @checkout).then { |done| done.out if done.ok? }

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
        def lock_file = File.join(common_dir, LOCK)

        # @return [String] the repository's common git directory, where the markers are kept
        def common_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir").strip

        # @param base [String] a commit
        # @param tip [String] a commit
        # @return [Boolean] whether `base` is `tip` or one of its ancestors
        def ancestor?(base, tip) = @git.capture("merge-base", "--is-ancestor", base, tip, chdir: @checkout).ok?

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
