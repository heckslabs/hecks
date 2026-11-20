# frozen_string_literal: true

require_relative "console_capture"
require_relative "main_integration"
require_relative "main_integration/repository"
require_relative "main_integration/checks"
require_relative "main_integration/command_runner"
require_relative "main_integration/cargo_target"
require_relative "main_integration/failure_log"
require_relative "main_integration/refusal"
require_relative "main_integration/bisecting"
require_relative "main_integration/local_mode"

module Hecks
  module Adapters
    # The `MainVerifying` port's adapter for `Integration.Verify`: checks a landed commit in a
    # clean detached copy of it, holding no local Hecks files, by running every check `Checks`
    # names there: the quick gate, all the listener promises before a push (CI on the train pull
    # request is the full check). These commits are answered `superseded` without a check: one
    # holding no hecks launcher (a project on the hecks gem landed it), one other than the head of
    # local main, one `origin/main` already contains (`CarriedCheck`) or an open
    # train pull request holds (`BoardedCheck`), judged before every check and after the last.
    # A failing check refuses the verification: the first line names every failing check, and a
    # block for each keeps its last `TAIL` lines. The copy's crates build into the shared Cargo
    # targets of their toolchain (`CargoTarget`), so a second verification reuses them.
    class MainVerification
      # How many of a failing check's last output lines a refusal keeps.
      TAIL = 60

      # Where a failed check's log is kept, the newest `FailureLog::KEEP` of them.
      LOG_DIRECTORY = File.join(Dir.home, ".claude", "hecks-dev", "verification-logs")

      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it so no check has to run.
        attr_accessor :runner

        # @return [String, nil] where failed checks keep their logs; `LOG_DIRECTORY` when nil. A
        #   spec sets a temporary one so it never writes under the owner's home.
        attr_accessor :log_directory

        # @return [#call, nil] stands in for the impacted-spec run of a verification made while the
        #   shallow check is off: given the changed paths and the commit they were read against,
        #   it answers a `GitShallowCheck::ImpactedRun::Outcome`; the real run when nil
        attr_accessor :impacted

        # @return [#call, nil] stands in for the spec run of one search probe: given a clean copy's
        #   directory and the failing spec files, it returns, or raises `ConsoleCapture::Failure`
        #   when one is red; the launcher run ({MainIntegration::SpecProbe}) when nil
        #   A red train's search hands it one failing example (`spec/x_spec.rb:12`) in place of the
        #   files, and runs {MainIntegration::ExampleProbe} when nil.
        attr_accessor :specs
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @failures = []
        @carried = nil
      end

      # @param held [Hash] the `Integration` record: `landed` and `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`verified` or `superseded`) and `report:`
      # @raise [ConsoleCapture::Failure] naming every check that failed
      def check(**held)
        landed = plain(held[:landed]).to_s
        repository = repository_of(held)
        return foreign(landed, repository) unless repository.launcher?(landed)

        head = repository.main
        return superseded(landed, head) unless head == landed

        mode = MainIntegration::LocalMode.new(repository)
        mode.verifies? ? verified(repository, landed, mode) : answer("verified", mode.unchecked(landed))
      end

      # The facts about the first bad merge of a failed verification's range, as the domain's rule
      # about reverting reads them. The search runs outside any copy, one probe at a time. A red
      # train names its failing `examples`: its range is what the train holds beyond `origin/main`,
      # and the world's local verification setting, which CI's verdict does not depend on, is not
      # asked.
      #
      # @param held [Hash] the `Integration` record: `landed` and `checkout`, and the `examples`
      #   of a red train
      # @return [Hash{Symbol => Hash}] each fact as a value: `base`, `culprit`, `branch`, `subject`,
      #   `spec`, `example`, `base_red`, `already_reverted`, `local` and `reason`
      def bisect(**held)
        landed = plain(held[:landed]).to_s
        repository = repository_of(held)
        train = MainIntegration::Bisecting.train(repository, landed, plain(held[:examples]), runner: self.class.specs)
        return train if train

        MainIntegration::LocalMode.new(repository).search!
        since, _changed, off = range_of(repository, landed)
        MainIntegration::Bisecting.answer((searched(repository, landed, since) if off), since)
      end

      private

      def verified(repository, landed, mode)
        repository.refresh
        passed = run_checks(repository, landed)
        return carried(landed) if @carried

        answer("verified", "#{landed[0, 10]} verified: #{passed.join(", ")}#{mode.remember(landed)}")
      end

      def repository_of(held) = MainIntegration::Repository.new(plain(held[:checkout]) || Dir.pwd)

      # While the shallow check is off, the specs run here, after the merge: those the landings
      # since the last verified commit touch. Otherwise (or with no marker, or one this commit
      # does not descend from) the range is the one the commit adds to `origin/main`.
      def range_of(repository, landed)
        off = MainIntegration::LocalMode.new(repository).impacted?
        since = (off && last_verified(repository, landed)) || repository.remote_main
        [since, repository.changed(since, landed), off]
      end

      # @return [String, nil] the commit the marker names, when the commit being verified descends
      #   from it
      def last_verified(repository, landed)
        last = MainIntegration::LastVerified.read(repository.common_dir)&.fetch("sha", nil)
        last if last && repository.commit(last) && repository.ancestor?(last, landed)
      end

      def checks_in(directory, changed, since, off)
        MainIntegration::Checks.new(directory, changed, since: since, shallow_off: off, impacted: self.class.impacted).all
      end

      def run_checks(repository, landed)
        since, changed, off = range_of(repository, landed)
        passed = repository.clean_copy(landed) { |directory| run_in(repository, landed, directory, [changed, since, off]) }
        refuse!(repository, landed, since, off) unless @carried || @failures.empty?
        passed
      end

      def run_in(repository, landed, directory, range)
        MainIntegration::CargoTarget.link(directory)
        checks = checks_in(directory, *range)
        checks.each { |name, argv| carried_now?(repository, landed) || record(landed, name, argv, directory) }
        carried_now?(repository, landed)
        checks.map(&:first)
      end

      # Asks, before a check, whether `origin/main` has come to carry the commit; once it does,
      # every check after is skipped.
      def carried_now?(repository, landed)
        return true if @carried

        repository.refresh
        @carried = repository.carried_by(landed)
        !@carried.nil?
      end

      def carried(landed) = answer("superseded", "#{landed[0, 10]} #{@carried}; no further check run")

      def record(landed, name, argv, directory)
        ok, output = argv.respond_to?(:call) ? argv.call(chdir: directory) : runner.call(argv, chdir: directory)
        @failures << failure(landed, name, Array(argv), output) unless ok
        ok
      end

      def failure(landed, name, argv, output)
        log = MainIntegration::FailureLog.new(self.class.log_directory || LOG_DIRECTORY).keep(landed, name, argv, output)
        MainIntegration::Refusal::Failure.new(name, tail(output), log, MainIntegration::FailureLog.finding(output))
      end

      # Raised after the copy is released, so the search for the first bad merge never holds the
      # copy's turn. It runs for every failed verification while the shallow check is off, so the
      # refusal names the first bad merge; a search that cannot run is said, never hidden.
      def refuse!(repository, landed, since, off)
        found = searched(repository, landed, since) if off
        raise ConsoleCapture::Failure, MainIntegration::Refusal.new(landed, @failures, TAIL, first_bad: found).to_s
      end

      def searched(repository, landed, since)
        failing = MainIntegration::FailureLog.new(self.class.log_directory || LOG_DIRECTORY).specs_for(landed)
        MainIntegration::Bisecting.search(repository, landed, since, failing: failing, runner: self.class.specs)
      end

      def superseded(landed, head)
        answer("superseded", "#{landed[0, 10]} is not the head of main (#{head[0, 10]}); the run for the head carries it")
      end

      def foreign(landed, repository)
        answer("superseded", "#{landed[0, 10]} landed in #{repository.checkout}, which holds no " \
                             "#{CheckoutGate::LAUNCHER}: main integration is hecks's own; no check run")
      end

      def answer(outcome, report) = { outcome: { value: outcome }, report: { value: report } }

      def tail(output) = output_lines(output).last(TAIL).join.chomp

      def output_lines(output) = output.to_s.strip.lines

      def runner = self.class.runner || MainIntegration::CommandRunner.new

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
