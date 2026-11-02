# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "git_train/reading"
require_relative "git_train/bench"
require_relative "git_train/local_branch"
require_relative "git_train/carriage"
require_relative "git_train/survey"
require_relative "git_train/settlement"
require_relative "git_train/mint_step"
require_relative "git_train/launcher_shape"
require_relative "git_train/hold"
require_relative "red_main_line"

module Hecks
  module Adapters
    # The `Train` port's adapter: pushes a checkout's branch one push at a time per repository.
    #
    # A boarding takes an exclusive `flock` on a file in the repository's common git directory, so
    # every worktree of one repository waits in the same line, and holds it until its push ends.
    # Waiting costs nothing: the pre-push checks of one push run at a time instead of all at once.
    #
    # Holding the line, a boarding names the commit the branch holds (`boarded`), checks that the
    # train runs that commit's shape (`LauncherShape`), runs the Hecks mint (`MintStep`), then
    # settles and pushes: one step after the other, so a refusal stops the boarding before
    # anything is pushed. What is pushed is that commit, settled, and nothing else: a branch that
    # moved meanwhile is refused.
    class GitTrain
      include Reading

      # The lock's file, in the repository's common git directory.
      LOCK_FILE = "hecks-push-train.lock"

      # Accepts the arguments every driven adapter is built with.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `marker:` a `QaQuiesceMarker`, for a spec
      # @param root [String, nil] unused
      # @param options [Hash] `mint:` the mint a boarding runs first (the Hecks domain's by default);
      #   `domain:` the launcher's Hecks domain directory the train's shape is read from (the one this
      #   code runs from by default); `registry:` the booted registry whose world names the landing
      #   queue's limits; any other key tunes the push hold's landing line (see `GitLanding::Lineup`)
      def initialize(aggregate: nil, settings: {}, root: nil, **options)
        @registry = options.delete(:registry)
        @marker = settings[:marker] || QaQuiesceMarker.new
        @mint = options.delete(:mint) || MintStep.new
        @domain = options.delete(:domain) || JournalStore::HeldMint::DOMAIN
        @tune = options
        @git = Git.new
      end

      # Waits for the push ahead in the same repository, runs the Hecks mint, then carries the
      # boarded commit.
      #
      # @param held [Hash] the `SendTrain` record: `run`, `confirm`, `branch`, `remote`, `checkout`
      #   (a directory inside the repository; the current directory when none is named) and
      #   `full_gate` (the whole pre-push stage, which the hook reads as `hecks.fullGate`)
      # @return [Hash{Symbol => Hash}] `outcome:`, `checkout:`, `boarded:` (the commit named at
      #   boarding), `pushed:` and `report:`, which opens with what the mint did
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository, the branch moved
      #   since boarding, the train is not at the boarded commit, the branch and the remote's
      #   conflict, or the push is refused
      # @raise [Runtime::WiringError] when the mint refuses, before anything is pushed
      def carry(**held)
        @checkout = toplevel(plain(held[:checkout]) || Dir.pwd)
        in_turn do
          boarded = boarded_commit(held)
          LauncherShape.new(@git, @checkout, domain: @domain).check!(boarded)
          minted = @mint.run(run: plain(held[:run]), confirm: plain(held[:confirm]))
          after_mint(minted, boarded, holding_main(held, boarded))
        end
      end

      # Lists every checkout under a directory whose default branch has commits its remote does
      # not, fetching each first.
      #
      # @param held [Hash] the `PushTrain` record: `checkout` (the directory whose children are
      #   surveyed; the current directory when none is named) and `remote`
      # @return [Hash{Symbol => Hash}] `report:` one line per checkout with unpushed commits
      # @raise [ConsoleCapture::Failure] when the directory does not exist
      def tally(**held)
        root = plain(held[:checkout]) || Dir.pwd
        raise ConsoleCapture::Failure, "#{root} is not a directory" unless File.directory?(root)

        { report: { value: Survey.new(@git, root, remote: plain(held[:remote]) || "origin").report } }
      end

      private

      # The commit the branch names as the boarding begins, read once the line is held.
      def boarded_commit(held)
        Carriage.new(@git, @checkout, branch: branch_of(held), remote: remote_of(held)).local_head
      end

      # Holds the landing line and QA quiet from the settlement to the push result, so local main
      # cannot move between the final check and the push.
      def holding_main(held, boarded)
        settled = nil
        hold = Hold.new(git_dir, @checkout, branch: branch_of(held), marker: @marker, setting: landing_setting, **@tune)
        answer = hold.around do
          carried, settled = settle_and_carry(held, boarded)
          carried
        end
        [answer, settled]
      end

      def landing_setting = (@registry&.world("Hecks")&.settings || {})["landing"]

      def git_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir")

      # Brings the branch up to its remote and settles the shape ledger, then carries the settled
      # commit.
      def settle_and_carry(held, boarded)
        branch = branch_of(held)
        remote = remote_of(held)
        settled = Settlement.new(@git, @checkout, branch: branch, remote: remote).run(boarded)
        carriage = Carriage.new(@git, @checkout, branch: branch, remote: remote, config: gate_config(held)).under_hold
        [carriage.carry(settled), settled]
      end

      def branch_of(held) = plain(held[:branch]) || "main"

      def remote_of(held) = plain(held[:remote]) || "origin"

      # The carriage's answer, its report opened with the red-main line while one is open, then what
      # the mint did and naming the boarded
      # commit (and the settled one when settlement moved the branch).
      def after_mint(minted, boarded, carried)
        answer, settled = carried
        named = settled == boarded ? "boarded #{boarded[0, 9]}" : "boarded #{boarded[0, 9]}, settled to #{settled[0, 9]}"
        report = "#{RedMainLine.lead}#{minted}, then #{named}: #{answer.dig(:report, :value)}"
        answer.merge(boarded: { value: boarded }, report: { value: report })
      end

      # A git hook takes no arguments, so the argument reaches the pre-push hook as git
      # configuration, for this push only (`git -c`).
      def gate_config(held) = plain(held[:full_gate]) == true ? ["-c", "hecks.fullGate=true"] : []

      def in_turn
        path = File.join(git_dir, LOCK_FILE)
        File.open(path, File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def toplevel(dir)
        raise ConsoleCapture::Failure, "#{dir} is not a directory" unless File.directory?(dir)

        read("rev-parse", "--show-toplevel", dir: dir)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
