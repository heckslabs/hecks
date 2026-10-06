module Hecks
  module Fuzzing
    module Mutation
      # What a mutation run tried and how each mutant ended.
      #
      # The score is killed mutants over killed plus survived: the share of behavior-changing
      # mutants the checks caught. Unreached and invalid mutants say nothing about the checks, so
      # they stay out of it.
      class Report
        # What the run was, for the report's heading.
        #
        # @!attribute [r] domain
        #   @return [String] the domain's name
        # @!attribute [r] seed
        #   @return [Integer] the run's seed
        # @!attribute [r] available
        #   @return [Integer] how many sites the operators found in all
        # @!attribute [r] sequences
        #   @return [Integer] how many generated sequences each mutant was replayed against
        # @!attribute [r] corpus
        #   @return [Boolean] whether a corpus script was replayed too
        Facts = Struct.new(:domain, :seed, :available, :sequences, :corpus)

        SURVIVED = "SURVIVED — behavior changed and no property, corpus expectation or behaviors test failed:".freeze
        UNREACHED = "UNREACHED — no sequence told these apart from the original (equivalent, or never exercised):".freeze

        attr_reader :facts, :verdicts

        # @param facts [Facts] what the run was
        # @param verdicts [Array<Outcome>] one per mutant tried
        def initialize(facts, verdicts)
          @facts = facts
          @verdicts = verdicts
        end

        %i[killed survived unreached invalid].each do |status|
          define_method(status) { verdicts.select { |outcome| outcome.status == status } }
        end

        # @return [Float, nil] killed / (killed + survived), nil when no mutant changed behavior
        def score
          judged = killed.size + survived.size
          judged.zero? ? nil : killed.size.fdiv(judged)
        end

        # @param minimum [Float] the lowest score that still passes
        # @return [Boolean] whether the score is at least `minimum`; a run with nothing judged
        #   passes
        def passes?(minimum) = score.nil? || score >= minimum

        # @return [String] the report as the command prints it
        def to_s
          [title, tally, *section(SURVIVED, survived), *section(UNREACHED, unreached)].join("\n")
        end

        private

        def title
          score_text = score ? format("%.0f%%", score * 100) : "n/a"
          "mutation #{facts.domain} (seed #{facts.seed}): #{verdicts.size} of #{facts.available} mutants tried " \
            "against #{facts.sequences} sequence(s)#{" and the corpus script" if facts.corpus} — score #{score_text}"
        end

        def tally
          "  killed #{killed.size}, survived #{survived.size}, unreached #{unreached.size}, invalid #{invalid.size}"
        end

        def section(heading, outcomes)
          outcomes.empty? ? [] : ["", heading, *outcomes.map { |outcome| describe(outcome.site) }]
        end

        def describe(site)
          "  #{site.id}  #{Operators::CATALOG.fetch(site.operator)}\n    was: #{site.original.strip}"
        end
      end
    end
  end
end
