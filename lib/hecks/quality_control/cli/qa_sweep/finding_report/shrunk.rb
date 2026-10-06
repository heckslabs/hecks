# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module FindingReport
        # The shrunk demonstrations of a finding: how far each shrank, the file it was written to
        # and the steps that remain.
        module Shrunk
          private

          def print_shrunk(shrunk, seed)
            path = write_shrunk!(shrunk, seed)
            budget = shrunk[:exhausted] ? ", budget exhausted — may shrink further" : ""
            puts "shrunk:      [#{shrunk[:mode]}] #{shrunk[:original_size]} -> #{shrunk[:steps].size} step(s) " \
                 "(#{shrunk[:attempts]} candidate checks#{budget})"
            puts "file:        #{path.delete_prefix("#{@root}/")}"
            puts "replay:      #{replay_command(shrunk, path)}"
            print_shrunk_steps(shrunk)
          end

          def replay_command(shrunk, path)
            if %i[differential self_consistency].include?(shrunk[:mode]) && @binary
              "hecks check_conformance domain=#{@domain_path} script=#{path} artifact=#{@binary}"
            else
              "hecks run #{@domain_path} #{path}"
            end
          end

          def print_shrunk_steps(shrunk)
            puts "-- shrunk steps [#{shrunk[:mode]}] --"
            shrunk[:steps].each_with_index do |step, index|
              kind = %w[verb query dry_run].find { |key| step.key?(key) }
              puts "#{index}: #{"#{kind} " unless kind == "verb"}#{step[kind]}  args: #{JSON.generate(step["args"])}"
            end
            puts
          end
        end
      end
    end
  end
end
