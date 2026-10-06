# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaPrCheck
      # What `clearance.check_pull_requests` prints once every tracked PR was looked at.
      module Reporting
        private

        def report_errors
          return if @operational_errors.empty?

          puts
          puts "operational error(s):"
          @operational_errors.each { |message| puts "  #{message}" }
        end

        def report_clean
          puts
          puts "clean — every PR QualityControl::Patch or QualityControl::Improvement tracks as open is " \
               "either already cleared, still running, or was retired this run."
          EXIT_OK
        end

        def report_newly_red
          print_newly_red_header
          @newly_red.each { |finding| print_finding(finding) }
          EXIT_NEWLY_RED
        end

        def print_newly_red_header
          puts
          puts "=" * 72
          puts "FOUND #{@newly_red.length} NEWLY-RED PR(S) — BugCiWatch/ImprovementCiWatch already dispatched " \
               "the matching Regress for each, by aggregate."
          puts "An agent picks up the investigation from here: the same judgment"
          puts "SKILL.md's own \"on a surprising check\" section describes for a sweep's"
          puts "own find — self-contained fix with a regression test and a draft PR,"
          puts "or leave the record for something bigger. Never re-verify from this script."
          puts "=" * 72
        end

        def print_finding(finding)
          puts
          puts "aggregate: #{finding[:aggregate]}"
          puts "citation:  #{finding[:citation]}"
          puts "pr:        ##{finding[:pr]}"
          puts "commit:    #{finding[:commit]}"
          puts "refusal:   #{finding[:refusal]}"
        end
      end
    end
  end
end
