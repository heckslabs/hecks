# frozen_string_literal: true

require "open3"
require "hecks/release/bump"
require_relative "console_capture"
require_relative "main_integration/release_cut_mark"

module Hecks
  module Adapters
    # The `Cutting` port's adapter for `NextRelease`: writes the bump of the version as one commit on
    # local main and boards it through the push train. Nothing is tagged or published here;
    # `release.yml` does that from `stable` once the bump has been promoted.
    #
    # It refuses a checkout that is not clean, not on `main`, or not level with `origin/main`, and
    # remembers the commit it made (`MainIntegration::ReleaseCutMark`) so the boarding guard lets the
    # version change through.
    class ReleaseCutting
      # The trailers that say who made the commit, as the push train asks of every commit.
      RUN_TRAILER = "Hecks-Run: release-cut"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `root:` the checkout, `today:` a call giving the date, `run:` takes
      #   `(argv, chdir:)` and answers `[output, ok]`, standing in for the process runner
      # @param root [String, nil] the checkout when `settings` names none
      # @param registry [Runtime::Registry, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @root = settings[:root] || root || Dir.pwd
        @today = settings[:today] || -> { Time.now.strftime("%Y-%m-%d") }
        @run = settings[:run] || method(:execute)
      end

      # The `Bump` ask.
      #
      # @param held [Hash] the `NextRelease` record: `level`
      # @return [Hash{Symbol => Hash}] the `version` cut
      # @raise [ConsoleCapture::Failure] when the checkout is not ready or git refuses
      def bump(**held)
        level = plain(held[:level])
        ready!
        version = Release::Bump.apply(@root, level: level, date: @today.call)
        git!("add", *Release::Bump::FILES)
        git!("commit", "-m", "Release v#{version}", "-m", "#{RUN_TRAILER}\nHecks-Work: release-cut")
        MainIntegration::ReleaseCutMark.record(git!("rev-parse", "HEAD").strip)
        board!
        { version: { value: version } }
      end

      private

      def ready!
        raise ConsoleCapture::Failure, "the checkout is not on main" unless git!("rev-parse", "--abbrev-ref", "HEAD").strip == "main"
        raise ConsoleCapture::Failure, "the checkout is not clean" unless git!("status", "--porcelain").strip.empty?

        git!("fetch", "origin", "main")
        return if git!("rev-parse", "HEAD") == git!("rev-parse", "origin/main")

        raise ConsoleCapture::Failure, "local main is not level with origin/main"
      end

      def board!
        out, ok = @run.call(["exe/hecks", "SendTrain.board!", "confirm.value=true"], chdir: @root)
        raise ConsoleCapture::Failure, "the train did not take the bump: #{out.to_s.lines.last}" unless ok
      end

      def git!(*args)
        out, ok = @run.call(["git", *args], chdir: @root)
        raise ConsoleCapture::Failure, "git #{args.first} failed: #{out.to_s.strip}" unless ok

        out
      end

      def execute(argv, chdir:)
        out, status = Open3.capture2e(*argv, chdir: chdir)
        [out, status.success?]
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
