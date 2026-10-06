require_relative "checks"

module Hecks
  module Fuzzing
    module Mutation
      # How one mutant fared.
      #
      # @!attribute [r] site
      #   @return [Site] what was changed
      # @!attribute [r] status
      #   @return [Symbol] `:killed`, `:survived`, `:unreached` or `:invalid`
      # @!attribute [r] by
      #   @return [String, nil] what killed it (`property: <name>`, `crash: <class>`, `corpus: ...`,
      #     `behavior: ...`), or why it is invalid
      Outcome = Struct.new(:site, :status, :by, keyword_init: true)

      # Replays one mutant and says which check, if any, noticed.
      #
      # The trials run in order and stop at the first that fails. Each answers whether it killed the
      # mutant and whether the mutant behaved differently from the original under it; a mutant that
      # differed everywhere it was looked at and was never killed survived.
      class Judge
        TRIALS = %i[sequence_trial corpus_trial behavior_trial].freeze

        # @param site [Site] what was changed
        # @param copy [String] the mutated copy of the domain
        # @param plan [Plan] what to replay
        # @param baseline [Hash] what `Checks.baseline` answered for the unmutated domain
        # @return [Outcome] the verdict
        def self.call(site, copy, plan, baseline) = new(site, copy, plan, baseline).call

        def initialize(site, copy, plan, baseline)
          @site = site
          @copy = copy
          @plan = plan
          @baseline = baseline
        end

        # @return [Outcome] invalid when it does not boot, killed by the first failing trial,
        #   otherwise survived or unreached by whether anything differed
        def call
          reason = Checks.boot_failure(@copy)
          return outcome(:invalid, reason) if reason

          run_trials
        rescue StandardError, ScriptError => e
          outcome(:killed, "crash: #{e.class}")
        end

        private

        def run_trials
          differed = false
          TRIALS.each do |trial|
            killer, changed = send(trial)
            return outcome(:killed, killer) if killer

            differed ||= changed
          end
          outcome(differed ? :survived : :unreached)
        end

        def outcome(status, by = nil) = Outcome.new(site: @site, status: status, by: by)

        def sequence_trial
          differed = false
          @plan.sequences.each_with_index do |steps, index|
            history = Replay.call(@copy, steps)
            broken = Checks.property_failure(history)
            return [broken, true] if broken

            differed ||= Observation.of(history) != @baseline[:sequences][index]
          end
          [nil, differed]
        end

        def corpus_trial
          return [nil, false] unless @plan.corpus

          report = Checks.corpus_report(@copy, @plan.corpus)
          unmet = Checks.unmet_expectation(@plan.corpus, report)
          return ["corpus: #{unmet}", true] if unmet

          [nil, Observation.of(report) != @baseline[:corpus]]
        end

        def behavior_trial
          failing = (Checks.failing_behaviors(@copy) - @baseline[:failing_behaviors]).first
          [failing && "behavior: #{failing}", !failing.nil?]
        end
      end
    end
  end
end
