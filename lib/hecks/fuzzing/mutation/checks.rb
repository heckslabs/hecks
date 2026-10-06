require_relative "../../cli/run"
require_relative "../../behaviors"
require_relative "observation"

module Hecks
  module Fuzzing
    module Mutation
      # What is replayed against a domain and its mutants: the generated sequences, the corpus
      # script and the domain's own `.behaviors` tests.
      #
      # @!attribute [r] sequences
      #   @return [Array<Array<Hash>>] generated step lists, valid for the unmutated domain
      # @!attribute [r] corpus
      #   @return [Hash, nil] the parsed corpus script
      Plan = Struct.new(:sequences, :corpus)

      # The checks a mutant is held to, each answering what it saw.
      module Checks
        module_function

        # What the unmutated domain does under the plan, as values a mutant's run is compared to.
        #
        # @param domain [String] the domain directory
        # @param plan [Plan] what to replay
        # @return [Hash] `:sequences` an observation per sequence, `:corpus` one for the script and
        #   `:failing_behaviors` the `.behaviors` tests that already fail
        def baseline(domain, plan)
          { sequences:         plan.sequences.map { |steps| Observation.of(Replay.call(domain, steps)) },
            corpus:            plan.corpus && Observation.of(corpus_report(domain, plan.corpus)),
            failing_behaviors: failing_behaviors(domain) }
        end

        # @return [String, nil] why the copy cannot boot, nil when it does
        def boot_failure(copy)
          Replay.call(copy, [])
          nil
        rescue StandardError, ScriptError => e
          "#{e.class}: #{e.message.lines.first.to_s.strip}"
        end

        # @return [String, nil] the first property a history breaks, as `property: <name>`
        def property_failure(history)
          broken = Properties.check(history).find { |_, result| result != true }
          broken && "property: #{broken.first}"
        end

        # The report `hecks run` would print for the script.
        def corpus_report(domain, corpus)
          IsolatedBoot.call(domain) do |copy|
            CLI::Run.execute(Hecks.boot(copy, environment: nil), corpus.fetch("steps"))
          end
        end

        # @return [String, nil] the first expectation of the script the report does not meet
        def unmet_expectation(corpus, report)
          unmet = CLI::RunExpectations.unmet(corpus["expectations"] || {}, report).first
          unmet && unmet.lines.first.strip
        end

        # The `.behaviors` tests of the domain that do not pass, by description.
        #
        # @param domain [String] the domain directory
        # @return [Array<String>] empty when every test passes or the domain has none
        def failing_behaviors(domain)
          Behaviors.run_all(domain).files.flat_map { |file| failures_in(file) }
        end

        def failures_in(file)
          return ["#{file.path}: #{file.parse_error}"] if file.parse_error

          file.runs.reject { |run| run.status == :pass }.map(&:description)
        end
      end
    end
  end
end
