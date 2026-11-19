# frozen_string_literal: true

require "etc"
require "securerandom"
require "time"
require_relative "trials/ledger"
require_relative "trials/pass_k"
require_relative "trials/gate_results"

module Hecks
  module Adapters
    module Codebase
      # The trial record of the spec batches and gate runs: each subject's result in each run, kept
      # with the machine's load and cpu count, and the pass^k lines a report ends with.
      #
      # It rides the `SourceTree` port as the gate and the spec batches do. Recording never refuses
      # a run: a log it cannot write turns into one line saying so.
      class Trials
        # @param ledger [Ledger] where the rows are kept
        # @param clock [#call] answers the time
        # @param load [#call, nil] answers the one-minute load average; `uptime`'s when nil
        # @param cpus [Integer] the machine's cpu count
        def initialize(ledger: Ledger.new, clock: -> { Time.now.utc }, load: nil, cpus: Etc.nprocessors)
          @ledger = ledger
          @clock = clock
          @load = load || -> { machine_load }
          @cpus = cpus
        end

        # Records one run and answers its pass^k lines.
        #
        # @param kind [String] the kind of run, such as `spec` or `gate-quick`
        # @param results [Hash{String => Boolean}] each subject, and whether it passed
        # @return [String, nil] the pass^k lines; nil when the run had no subject
        def record(kind, results)
          return nil if results.empty?

          @ledger.append(rows(kind, results))
          summary(kind, results.keys)
        rescue SystemCallError, IOError => e
          "trials not recorded: #{e.message}"
        end

        # @param kind [String] the kind of run
        # @param subjects [Array<String>] the subjects to report on
        # @return [String] the batch's pass^k and a line for each subject that has failed a run
        def summary(kind, subjects)
          tallies = PassK.tallies(@ledger.read(kind), subjects)
          [headline(tallies), *tallies.select(&:failed?).map { |tally| "  #{line(tally)}" }].join("\n")
        end

        private

        def rows(kind, results)
          stamp = { "run" => SecureRandom.uuid, "at" => @clock.call.iso8601, "kind" => kind,
                    "load" => @load.call, "cpus" => @cpus }
          results.map { |subject, passed| stamp.merge("subject" => subject, "passed" => passed) }
        end

        def headline(tallies)
          figure = PassK.batch(tallies)
          counted = tallies.count(&:counted?)
          return "pass^#{PassK::K}: no subject has #{PassK::MIN_RUNS} runs yet" unless figure

          "pass^#{PassK::K}: #{format("%.2f", figure)} over #{counted} subject(s) with " \
            "#{PassK::MIN_RUNS}+ runs (the bound if runs were independent)"
        end

        def line(tally)
          "#{tally.subject}: #{tally.passes} of #{tally.runs} passed, pass^#{PassK::K} #{format("%.2f", tally.pass_k)}"
        end

        def machine_load
          require_relative "../dispatching/settings"
          Dispatching::Settings.uptime_load
        rescue StandardError
          nil
        end
      end
    end
  end
end
