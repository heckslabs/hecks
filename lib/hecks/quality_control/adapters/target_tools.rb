# frozen_string_literal: true

require_relative "qa_tool"

module Hecks
  module Adapters
    # The `TargetTools` port's adapter: answers `Target`'s queries by running the QA commands that
    # enrol, generate and judge chapters: the seed, the generated-domain check, the combination
    # miner, the novelty gate and the external-domain scan. A finding or a judgment is an answer;
    # anything else the command calls an error is refused with its report.
    class TargetTools < QaTool
      # @return [Hash] `text:` each corpus domain's outcome: identified, or already on file
      def seed
        run_command("qa_seed_targets")
      end

      # @param arguments [Hash, String, nil] the command's own flags, such as `--domains 3 --rust`
      # @return [Hash] `text:` the report of the generated domains' check
      def check_generated_domains(arguments: nil)
        run_command("qa_generated_domains", *words(arguments), answers: [0, 2])
      end

      # @param arguments [Hash, String, nil] the command's own flags, such as `--brief`
      # @return [Hash] `text:` the miner's report
      def mine_combinations(arguments: nil)
        run_command("qa_mine_combinations", *words(arguments), answers: [0, 1])
      end

      # @param domain [Hash, String] the candidate stress domain's path
      # @param arguments [Hash, String, nil] `--against` and the paths to compare with
      # @return [Hash] `text:` the new form pairs it earns its place with, or that it earns none
      def judge_novelty(domain:, arguments: nil)
        run_command("qa_domain_novelty", plain(domain), *words(arguments), answers: [0, 1])
      end

      # @param arguments [Hash, String, nil] the command's own flags, such as `--max-depth 4`
      # @return [Hash] `text:` the sibling domains that depend on hecks and are not enrolled
      def discover_external_domains(arguments: nil)
        run_command("qa_discover_external_domains", *words(arguments))
      end
    end
  end
end
