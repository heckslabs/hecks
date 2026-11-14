# frozen_string_literal: true

require "rbconfig"
require "fileutils"
require_relative "console_capture"
require_relative "ticker_persistence"
require_relative "git_train"
require_relative "ticking/chain"

module Hecks
  module Adapters
    # The `Ticking` port's adapter for `Ticker`: starts one detached process that sleeps the world's
    # period and dispatches `Ticker.tick!` through the launcher, over and over, until a dispatch is
    # refused. It measures time and dispatches; whether the chain goes on (the pull request is
    # still open, the beats are within the limit) is the bluebook's, which refuses a tick that is
    # not wanted.
    class Ticking
      # The Tickets world verb that carries the period in `seconds` and the allowance in `minutes`.
      VERB = "ticks"

      # Seconds between two ticks when the world names none.
      SECONDS = 20

      # Minutes a chain may tick when the world names none.
      MINUTES = 30

      # The characters of a run key that are replaced when the key names a log file.
      UNSAFE_IN_FILENAME = /[^\w.-]/

      # What the child runs: the {Chain} loop, required from its file. The arguments are the run,
      # the quick period in seconds, the launcher, the minutes the chain may run (absent for none)
      # and the log path last. The schedule and the branch to watch arrive in the environment
      # (`HECKS_TICK_BACKOFF`, `HECKS_TICK_WATCH`). Each statement is one line: the lines are joined
      # with `;` to pass the script to `ruby -e`.
      CHAIN = <<~RUBY.tr("\n", ";").freeze
        require "#{File.join(__dir__, "ticking", "chain")}"
        Hecks::Adapters::Ticking::Chain.run(ARGV)
      RUBY

      # @param registry [Runtime::Registry, nil] the booted registry whose world is read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `spawner:` starts the chain from its argument list (a stand-in in
      #   specs), `seconds:` and `minutes:` stand in for the world
      # @param root [String, nil] the checkout whose `exe/hecks` each tick dispatches through
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
        @root = root || Dir.pwd
      end

      # Starts the chain of ticks for a run.
      #
      # @param held [Hash] the `Ticker` record: `run`
      # @return [Hash{Symbol => Hash}] `limit:` how many beats the world's minutes allow
      # @raise [ConsoleCapture::Failure] when the checkout has no launcher to dispatch through
      def open(**held)
        launcher = launcher!
        run = plain(held[:run])
        spawner.call(environment(run), *child(run, launcher, logfile(run)))
        { limit: { value: backoff.limit(minutes) } }
      end

      private

      # The checkout's launcher, once a chain can run: its ticks need the launcher and a Ticker
      # record that outlives this process.
      def launcher!
        launcher = File.join(@root, "exe", "hecks")
        raise ConsoleCapture::Failure, "no launcher at #{launcher}" unless File.executable?(launcher)
        raise ConsoleCapture::Failure, persistence.refusal unless persisted?

        launcher
      end

      def child(run, launcher, log)
        [RbConfig.ruby, "-e", CHAIN, run, backoff.quick.to_s, launcher, minutes.to_s, log]
      end

      # What the child inherits besides the caller's name: the schedule it waits by and the train
      # branch of the run whose checks it watches (named by the boarding, from the run's commit).
      def environment(run)
        { "HECKS_CALLER" => "ticker", "HECKS_TICK_BACKOFF" => backoff.to_s,
          "HECKS_TICK_WATCH" => GitTrain::PullRequestBoarding.branch_for(run) }
      end

      # The schedule the world declares, or the defaults: `quick` seconds (at most `SECONDS`) for
      # the first `quick_for`, then each of `steps`, the last one for good.
      def backoff
        @backoff ||= Backoff.new(quick:     declared[:quick] || [seconds, SECONDS].min,
                                 quick_for: declared[:quick_for] || Backoff::QUICK_FOR,
                                 steps:     Array(declared[:steps] || Backoff::STEPS))
      end

      # The file the chain writes its beginning, each tick's status and its end to, and where the
      # child's own stdout and stderr go; its directory exists once a chain is asked for.
      def logfile(run)
        dir = @standins[:dir] || File.join(Dir.home, ".claude", "hecks-dev", "ticker")
        FileUtils.mkdir_p(dir)
        File.join(dir, "#{run.gsub(UNSAFE_IN_FILENAME, "_")}.log")
      end

      def persistence = @persistence ||= TickerPersistence.new(@registry)

      def persisted? = @standins.fetch(:persisted) { persistence.persisted? }

      def spawner = @standins[:spawner] || method(:detach)

      def detach(env, *argv)
        Process.detach(Process.spawn(env, *argv, in: File::NULL, out: [argv.last, "a"], err: [:child, :out], pgroup: true))
      end

      def seconds = (@standins[:seconds] || declared[:seconds] || SECONDS).to_f

      def minutes = (@standins[:minutes] || declared[:minutes] || MINUTES).to_f

      def declared = @registry&.world("Tickets")&.for_verb(VERB) || {}

      def plain(value) = value.is_a?(Hash) ? value[:value].to_s : value.to_s
    end
  end
end
