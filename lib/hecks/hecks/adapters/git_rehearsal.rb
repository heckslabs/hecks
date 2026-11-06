# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "git_rehearsal/reading"
require_relative "git_rehearsal/bench"
require_relative "git_rehearsal/stages"
require_relative "git_rehearsal/record"
require_relative "git_rehearsal/due"
require_relative "git_rehearsal/line"
require_relative "red_main_line"

module Hecks
  module Adapters
    # The `Rehearsing` port's adapter for `PushRehearsal`: runs, against local `main` and without
    # pushing, the stages of a scope, and reports whether a push is due.
    #
    # A scope is a `RehearsalScope` row of the Vocabulary bluebook: `quick` (the gate's quick
    # stage; a landing asks), `full` (the quick stage again; a push needs it)
    # or `deep` (full plus the impacted specs; opt-in). Quick has its own line, record and bench, so
    # it runs alongside a full one; deep shares the full one's. A rehearsal checks out a detached
    # copy of `main`, runs the scope's stages in it and removes it. It pushes nothing and writes
    # only a one-line record in the common git directory, which the `Due` query reads back.
    class GitRehearsal
      include Reading

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `impacted_spec_limit:` the most impacted spec files run (60);
      #   `impacted_spec_width:` how many run at once (2)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
        @impacted_limit = settings[:impacted_spec_limit]
        @impacted_width = settings[:impacted_spec_width]
      end

      # Rehearses the push of a branch, one at a time per repository and scope.
      #
      # A land that arrives while one runs marks `pending: rehearse <sha>` and is refused with that
      # sentence; the running rehearsal then runs once more for the latest commit, however many
      # landed. Benches a killed rehearsal left registered are removed first.
      #
      # @param held [Hash] the `PushRehearsal` record: `checkout`, `branch` (`main` by default) and
      #   `scope` (a `RehearsalScope` row: `full` by default, `quick` or `deep`)
      # @return [Hash{Symbol => Hash}] `outcome:` (`green` or `red`), `rehearsed:` the commit,
      #   `report:` one line per stage saying pass or fail
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository, has no such branch,
      #   or another rehearsal is running
      def trial(**held)
        @checkout = primary(plain(held[:checkout]) || Dir.pwd)
        branch = plain(held[:branch]) || "main"
        @scope = scope_of(plain(held[:scope]))
        in_line(branch, head(branch))
      end

      # Says whether a push is due, from what git already holds: nothing is fetched or pushed.
      #
      # @param held [Hash] `checkout` (a directory inside the repository)
      # @return [Hash{Symbol => String}] `text:` the commits ahead, the oldest one's age and the
      #   last rehearsal's result, led by the STOP line while main CI is red
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def due(**held)
        @checkout = primary(plain(held[:checkout]) || Dir.pwd)
        { text: RedMainLine.lead(checkout: @checkout) + Due.new(@git, @checkout).report }
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

      def queue = Line.new(@git, @checkout, scope: @scope)

      def scope_of(scope)
        return scope || "full" if scope.nil? || Stages.scopes.include?(scope)

        raise ConsoleCapture::Failure, "scope #{scope} is not a rehearsal scope: #{Stages.scopes.join(", ")}"
      end

      def head(branch) = read("rev-parse", "--verify", "refs/heads/#{branch}^{commit}")

      # Rehearses the commit, then once more for the latest of the branch for as long as a land has
      # marked one pending; answers the last rehearsal.
      def drain(branch, commit)
        Bench.new(@git, @checkout, scope: @scope).sweep
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
        results = Bench.new(@git, @checkout, scope: @scope).rehearse(commit) { |directory| stages(directory, branch).run }
        verdict = results.all?(&:passed) ? "green" : "red"
        note = Record.new(@git, @checkout).write(commit, verdict, results, scope: @scope)
        { outcome: { value: verdict }, rehearsed: { value: commit }, report: { value: report(branch, commit, results, note) } }
      end

      def report(branch, commit, results, note)
        lines = [heading(branch, commit)] + results.map(&:line)
        lines << note unless note == "recorded"
        lines.join("\n")
      end

      def stages(directory, branch)
        Stages.new(directory, branch: branch, impacted_limit: @impacted_limit,
                    impacted_width: @impacted_width, scope: @scope)
      end

      def heading(branch, commit)
        "#{@scope} rehearsal of #{branch} at #{short(commit)}; nothing was pushed"
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
