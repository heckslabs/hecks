# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "git_rehearsal/reading"
require_relative "git_rehearsal/bench"
require_relative "git_rehearsal/stages"
require_relative "git_rehearsal/record"
require_relative "git_rehearsal/due"
require_relative "git_rehearsal/line"

module Hecks
  module Adapters
    # The `Rehearsing` port's adapter for `PushRehearsal`: runs, against local `main` and without
    # pushing, the stages a real push runs, and reports whether a push is due.
    #
    # A rehearsal checks out a detached copy of `main` (as the push train's bench does), runs the
    # `quick` stage, the `unguarded_push` stage of the Vocabulary gate rows, any end-to-end push
    # specs and the specs the push's changes touch, and removes the copy. It pushes nothing and
    # writes only a one-line record of its result in the repository's common git directory, which
    # the `Due` query reads back.
    class GitRehearsal
      include Reading

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `impacted_spec_limit:` the most impacted spec files run (60)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
        @impacted_limit = settings[:impacted_spec_limit]
      end

      # Rehearses the push of a branch, one rehearsal at a time per repository.
      #
      # A land that arrives while one runs marks `pending: rehearse <sha>` and is refused with that
      # sentence; the running rehearsal then runs once more for the latest commit, however many
      # landed. Benches a killed rehearsal left registered are removed first.
      #
      # @param held [Hash] the `PushRehearsal` record: `checkout` (a directory inside the
      #   repository; the current directory when none is named) and `branch` (`main` by default)
      # @return [Hash{Symbol => Hash}] `outcome:` (`green` or `red`), `rehearsed:` the commit,
      #   `report:` one line per stage saying pass or fail
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository, has no such branch,
      #   or another rehearsal is running
      def trial(**held)
        @checkout = primary(plain(held[:checkout]) || Dir.pwd)
        branch = plain(held[:branch]) || "main"
        in_line(branch, head(branch))
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

      # Rehearses in the repository's line: at once when none runs, else marks the commit pending
      # and
      # tries the line once more in case the running rehearsal ended meanwhile.
      def in_line(branch, commit)
        answer = queue.running { drain(branch, commit) }
        return answer unless answer == :busy

        pending = queue.mark(branch, commit)
        answer = queue.running { drain(branch, queue.take && head(branch)) }
        answer.is_a?(Hash) ? answer : pending!(pending, branch)
      end

      def pending!(pending, branch)
        raise ConsoleCapture::Failure,
              "#{pending}: a rehearsal is already running in this repository and will run once more for the latest #{branch}"
      end

      def queue = Line.new(@git, @checkout)

      def head(branch) = read("rev-parse", "--verify", "refs/heads/#{branch}^{commit}")

      # Rehearses the commit, then once more for the latest of the branch for as long as a land has
      # marked one pending; answers the last rehearsal.
      def drain(branch, commit)
        Bench.new(@git, @checkout).sweep
        answer = nil
        while commit
          answer = once(branch, commit)
          again = queue.take
          commit = again && head(again)
          branch = again if again
        end
        answer
      end

      def once(branch, commit)
        results = Bench.new(@git, @checkout).rehearse(commit) { |directory| stages(directory, branch).run }
        verdict = results.all?(&:passed) ? "green" : "red"
        note = Record.new(@git, @checkout).write(commit, verdict, results)
        { outcome: { value: verdict }, rehearsed: { value: commit }, report: { value: report(branch, commit, results, note) } }
      end

      def report(branch, commit, results, note)
        lines = [heading(branch, commit)] + results.map(&:line)
        lines << note unless note == "recorded"
        lines.join("\n")
      end

      def stages(directory, branch) = Stages.new(directory, branch: branch, impacted_limit: @impacted_limit)

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
