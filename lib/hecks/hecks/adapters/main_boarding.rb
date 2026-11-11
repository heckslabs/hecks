# frozen_string_literal: true

require_relative "console_capture"
require_relative "main_integration"
require_relative "main_integration/repository"
require_relative "main_integration/range_guard"
require_relative "main_integration/train"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # The `MainBoarding` port's adapter for `Integration.Board`: pushes a verified commit of main
    # by boarding the push train in the train's own copy, and answers the commit the remote holds.
    #
    # It refuses, naming why, a run that was not verified, a boarding while another run is being
    # pushed or watched, and a range carrying an agent's attribution trailer, a release approval or
    # a version change. A commit other than the head of local main is answered `superseded`: the
    # run for the head pushes it. It never runs a plain push, a force, a skipped hook or the
    # owner's override: the train's command line is fixed and the override is not handed on.
    class MainBoarding
      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it so nothing is pushed.
        attr_accessor :runner

        # @return [String, nil] the train's copy; `Train::ROOT` when nil
        attr_accessor :train_root
      end

      # @param registry [Runtime::Registry, nil] the booted registry whose runs are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # @param held [Hash] the `Integration` record: `landed` and `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`pushed` or `superseded`), `pushed:`, `report:`
      # @raise [ConsoleCapture::Failure] on any refusal named above, or when the train did not push
      def embark(**held)
        landed = plain(held[:landed]).to_s
        refuse_unboardable!(landed)
        repository = MainIntegration::Repository.new(checkout_of(held))
        head = repository.main
        return superseded(landed, head) unless head == landed

        MainIntegration::RangeGuard.new(repository).check!(repository.remote_main, landed)
        push(landed, checkout_of(held))
      end

      private

      def checkout_of(held) = plain(held[:checkout]) || Dir.pwd

      def push(landed, checkout)
        train = MainIntegration::Train.new(runner, root: self.class.train_root || MainIntegration::Train::ROOT)
        note = train.refresh(landed)
        record = train.board(checkout)
        pushed = [record["pushed"], record["boarded"], landed].compact.first
        { outcome: { value: "pushed" }, pushed: { value: pushed.to_s },
          report: { value: "#{landed[0, 10]} #{record["status"]} as #{pushed.to_s[0, 10]}#{answer_of(record)}; #{note}" } }
      end

      # The last line of the train's own report, where a queued boarding names its pull request.
      def answer_of(record)
        said = last_line(record["report"].to_s)
        said.empty? ? "" : " (#{said})"
      end

      def last_line(text)
        lines = text.strip.lines
        lines.empty? ? "" : lines.last.strip
      end

      # The run must have come to boarding from verified (the saga moved it as the boarding
      # began), and no other run may be being pushed or watched.
      def refuse_unboardable!(landed)
        runs = MainIntegration::Runs.new(@registry)
        run = runs.find(landed) or refuse!("no integration run is keyed by #{landed[0, 10]}")
        refuse!("#{run.short} is #{run.state}, not verified") unless run.state == "boarding"
        other, = MainIntegration::TrainChecks.new.blocking(runs.in_flight(except: landed))
        refuse!("#{other.short} is #{other.state}; one run boards at a time") if other
      end

      def refuse!(why) = raise(ConsoleCapture::Failure, "boarding refused: #{why}")

      def superseded(landed, head)
        report = "#{landed[0, 10]} is not the head of main (#{head[0, 10]}); the run for the head pushes it"
        { outcome: { value: "superseded" }, report: { value: report } }
      end

      def runner = self.class.runner || MainIntegration::CommandRunner.new

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
