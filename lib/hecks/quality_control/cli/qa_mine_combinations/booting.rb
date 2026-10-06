# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module QualityControlCli
    class QaMineCombinations
      # The boot check of `target.mine_combinations`: which candidates boot, the repair rounds the
      # agent gets for those that do not, and the per-candidate report.
      module Booting
        private

        # @return [Array(Hash, Array<String>)] the slug-to-error map of candidates that never
        #   booted, and the slugs a repair round fixed
        def boot_and_repair(candidates)
          boot_root = File.join(@run_dir, "boot")
          failures = failing(candidates, boot_root)
          repaired = []
          @options[:repair_rounds].times do |round|
            break if failures.empty? || @options[:from]

            still = repair_round(round, failures, boot_root)
            repaired.concat(slugs(failures) - slugs(still))
            failures = still
          end
          [failures.to_h { |candidate, error| [candidate[:slug], error] }, repaired]
        end

        def slugs(failures)
          failures.map { |candidate, _| candidate[:slug] }
        end

        # @return [Array<Array>] the `[candidate, error]` pairs of candidates that do not boot
        def failing(candidates, boot_root)
          candidates.filter_map { |candidate| (error = boot_error(candidate, boot_root)) && [candidate, error] }
        end

        def repair_round(round, failures, boot_root)
          puts "repair round #{round + 1}: #{failures.size} candidate(s) did not boot — back to the agent…"
          failure = ask_agent(Miner.repair_prompt(failures, out_dir: @out_dir))
          abort "combination miner: #{failure}" if failure

          failing(failures.map(&:first), boot_root)
        end

        def boot_error(candidate, boot_root)
          dir = write_boot_domain(candidate, boot_root)
          output, = Open3.capture2e(*Child.argv(@root, "qa_generated_domains", "--check", dir, "--seeds", "0"),
                                    chdir: @root)
          line = output.lines.reverse.find { |candidate_line| candidate_line.start_with?(RESULT_MARKER) }
          return "boot check produced no result: #{output.lines.last(5).join.strip}" unless line

          result = JSON.parse(line.delete_prefix(RESULT_MARKER))
          result["status"] == "invalid" ? result["error"] : nil
        end

        def write_boot_domain(candidate, boot_root)
          Hecks::Fuzzing::DomainGenerator.write(
            { "source" => File.read(candidate[:bluebook]), "aggregates" => [], "policies" => [] },
            File.join(boot_root, candidate[:slug])
          )
        end

        def report(candidates, invalid, repaired)
          puts
          candidates.each do |candidate|
            if invalid.key?(candidate[:slug])
              puts "  #{candidate[:slug]}: INVALID — #{invalid[candidate[:slug]]}"
            else
              print_booted(candidate, repaired)
            end
          end
        end

        def print_booted(candidate, repaired)
          pairs = new_pairs_for(candidate)
          puts "  #{candidate[:slug]}: boots#{" (repaired)" if repaired.include?(candidate[:slug])}; " \
               "new pair(s): #{pairs.empty? ? "none" : pairs.join(", ")}"
          first = first_hypothesis_line(candidate)
          puts "    #{first}" if first
        end

        def first_hypothesis_line(candidate)
          candidate[:hypothesis].to_s.lines.map(&:strip).find { |line| !line.empty? && !line.start_with?("#") }
        end

        def new_pairs_for(candidate)
          Miner.new_pairs(candidate[:dir], @brief["covered"])
        rescue StandardError, ScriptError => e
          ["(census failed: #{e.class})"]
        end
      end
    end
  end
end
