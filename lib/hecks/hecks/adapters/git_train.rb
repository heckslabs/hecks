# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "push_size"
require_relative "git_train/reading"
require_relative "git_train/bench"
require_relative "git_train/local_branch"
require_relative "git_train/carriage"
require_relative "git_train/survey"
require_relative "git_train/settlement"
require_relative "git_train/mint_step"
require_relative "git_train/launcher_shape"
require_relative "git_train/red_stop"

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
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param options [Hash] `mint:` the mint a boarding runs first (the Hecks domain's if none);
      #   `domain:` the launcher's Hecks domain directory the train's shape is read from (the one
      #   this code runs from by default); `registry:` the booted registry whose world names the
      #   push size and declares the red-main stop; `reader:` and `clock:` stand in for GitHub and the time
      def initialize(aggregate: nil, settings: {}, root: nil, **options)
        @registry = options.delete(:registry)
        @stop_options = options.slice(:reader, :clock)
        @mint = options.delete(:mint) || MintStep.new
        @domain = options.delete(:domain) || JournalStore::HeldMint::DOMAIN
        @git = Git.new
      end

      # Waits for the push ahead in the same repository, runs the Hecks mint, then carries the
      # boarded commit.
      #
      # @param held [Hash] the `SendTrain` record: `run`, `confirm`, `branch`, `remote`, `checkout`
      #   (a directory inside the repository; the current directory when none is named),
      #   `full_gate` (the whole pre-push stage, which the hook reads as `hecks.fullGate`) and
      #   `fixes` (the open red Work row this push fixes, which a red main requires)
      # @return [Hash{Symbol => Hash}] `outcome:`, `checkout:`, `boarded:` (the commit named at
      #   boarding), `pushed:` and `report:`, which opens with what the mint did
      # @raise [ConsoleCapture::Failure] when main is red and `fixes` names no open red row (before
      #   anything is settled or minted), the checkout is not a repository, the branch moved
      #   since boarding, the train is not at the boarded commit, the branch and the remote's
      #   conflict, or the push is refused
      # @raise [Runtime::WiringError] when the mint refuses, before anything is pushed
      def carry(**held)
        @checkout = toplevel(plain(held[:checkout]) || Dir.pwd)
        @stop = RedStop.new(@registry, @checkout, **@stop_options)
        @stop.check!(plain(held[:fixes]))
        in_turn do
          size = push_size(held)
          boarded = boarded_commit(held)
          LauncherShape.new(@git, @checkout, domain: @domain).check!(boarded)
          minted = @mint.run(run: plain(held[:run]), confirm: plain(held[:confirm]))
          after_mint(minted, boarded, settle_and_carry(held, boarded), size)
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

      # Brings the branch up to its remote and settles the shape ledger, then carries the settled
      # commit.
      def settle_and_carry(held, boarded)
        branch = branch_of(held)
        remote = remote_of(held)
        settled = Settlement.new(@git, @checkout, branch: branch, remote: remote).run(boarded)
        carriage = Carriage.new(@git, @checkout, branch: branch, remote: remote, config: gate_config(held))
        [carriage.carry(settled), settled]
      end

      # What the push is, said before it is made: how many commits go and, past the world's
      # threshold, the size sentence. It only says; a push of any size is carried.
      def push_size(held)
        ahead = read("rev-list", "--count", "#{remote_of(held)}/#{branch_of(held)}..#{branch_of(held)}").to_i
        sentence = PushSize.sentence(ahead, PushSize.thresholds(@registry))
        sentence.empty? ? "pushing #{ahead} commits" : "pushing #{ahead} commits; #{sentence}"
      end

      def branch_of(held) = plain(held[:branch]) || "main"

      def remote_of(held) = plain(held[:remote]) || "origin"

      # The carriage's answer, its report opened with the stop line while main is red, then what
      # the mint did and naming the boarded
      # commit (and the settled one when settlement moved the branch).
      def after_mint(minted, boarded, carried, size = nil)
        answer, settled = carried
        named = settled == boarded ? "boarded #{boarded[0, 9]}" : "boarded #{boarded[0, 9]}, settled to #{settled[0, 9]}"
        report = "#{@stop.lead}#{"#{size}\n" if size}#{minted}, then #{named}: #{answer.dig(:report, :value)}"
        answer.merge(boarded: { value: boarded }, report: { value: report })
      end

      # A git hook takes no arguments, so the argument reaches the pre-push hook as git
      # configuration, for this push only (`git -c`).
      def gate_config(held) = plain(held[:full_gate]) == true ? ["-c", "hecks.fullGate=true"] : []

      def in_turn
        path = File.join(read("rev-parse", "--path-format=absolute", "--git-common-dir"), LOCK_FILE)
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
