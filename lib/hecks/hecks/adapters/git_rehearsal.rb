# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "git_rehearsal/reading"
require_relative "git_rehearsal/bench"
require_relative "git_rehearsal/stages"
require_relative "git_rehearsal/record"
require_relative "git_rehearsal/due"

module Hecks
  module Adapters
    # The `Rehearsing` port's adapter for `PushRehearsal`: runs, against local `main` and without
    # pushing, the stages a real push runs, and reports whether a push is due.
    #
    # A rehearsal checks out a detached copy of `main` (as the push train's bench does), runs the
    # `quick` stage, the `unguarded_push` stage of the Vocabulary gate rows and any end-to-end push
    # specs, and removes the copy. It pushes nothing and writes only a one-line record of its result
    # in the repository's common git directory, which the `Due` query reads back.
    class GitRehearsal
      include Reading

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Rehearses the push of a branch.
      #
      # @param held [Hash] the `PushRehearsal` record: `checkout` (a directory inside the
      #   repository; the current directory when none is named) and `branch` (`main` by default)
      # @return [Hash{Symbol => Hash}] `outcome:` (`green` or `red`), `rehearsed:` the commit,
      #   `report:` one line per stage saying pass or fail and naming the failing check and spec
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository or has no such branch
      def trial(**held)
        @checkout = primary(plain(held[:checkout]) || Dir.pwd)
        branch = plain(held[:branch]) || "main"
        commit = read("rev-parse", "--verify", "refs/heads/#{branch}^{commit}")
        results = Bench.new(@git, @checkout).rehearse(commit) { |directory| Stages.new(directory).run }
        verdict = results.all?(&:passed) ? "green" : "red"
        Record.new(@git, @checkout).write(commit, verdict, results)
        { outcome: { value: verdict }, rehearsed: { value: commit }, report: { value: report(branch, commit, results) } }
      end

      # Says whether a push is due, from what git already holds: nothing is fetched or pushed.
      #
      # @param held [Hash] `checkout` (a directory inside the repository)
      # @return [Hash{Symbol => String}] `text:` the commits ahead, the oldest one's age and the
      #   last rehearsal's result
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def due(**held)
        @checkout = primary(plain(held[:checkout]) || Dir.pwd)
        { text: Due.new(@git, @checkout).report }
      end

      private

      def report(branch, commit, results)
        ([heading(branch, commit)] + results.map(&:line)).join("\n")
      end

      def heading(branch, commit)
        "rehearsed #{branch} at #{short(commit)}; nothing was pushed"
      end

      # The repository's own checkout, found from any worktree of it.
      def primary(directory)
        raise ConsoleCapture::Failure, "#{directory} is not a directory" unless File.directory?(directory)

        common = read("rev-parse", "--path-format=absolute", "--git-common-dir", dir: directory)
        File.basename(common) == ".git" ? File.dirname(common) : common
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
