# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaGeneratedDomains
      # What `target.check_generated_domains` prints: a line per domain, and a block per finding.
      module Reporting
        private

        def relative(path) = path.delete_prefix("#{@root}/")

        def announce_run(start, run_dir)
          puts "generated domains: #{@options[:domains]} starting at seed #{start}; #{@options[:seeds]} seed(s) x " \
               "#{@options[:steps]} steps each, adversarial #{@options[:adversarial]}" \
               "#{", against Rust" if @options[:rust]} — #{relative(run_dir)}"
        end

        def print_finding_header(report)
          puts
          puts "=" * 72
          puts "GENERATED DOMAIN FOUND SOMETHING — domain seed #{report[:seed]}, forms #{report[:forms].join(" + ")}"
          puts "=" * 72
          print_finding_locations(report)
        end

        def print_finding_locations(report)
          puts "domain:      #{relative(report[:dir])}"
          puts "             shrunk from #{report[:size_before]} to #{report[:size_after]} removable element(s) " \
               "in #{report[:domain_attempts]} candidate check(s)"
          puts "blueprint:   #{relative(File.join(report[:root], "blueprint.json"))}"
        end

        def print_finding(report)
          found = report[:final]
          print_finding_header(report)
          print_finding_facts(found, report[:options])
          print_shrunk(report, found["steps"], found["shrunk_steps"])
          puts "promote:     hecks quality_control check_generated_domains --promote " \
               "#{relative(report[:root])} --name <stress_domain_name>"
          puts
          found["divergences"].each { |divergence| print_divergence(divergence) }
        end

        def print_finding_facts(found, options)
          puts "mode:        #{found["mode"]}"
          puts "signature:   #{found["signature"].join(", ")}"
          return unless found["seed"]

          puts "sequence:    seed #{found["seed"]} of --seeds #{options[:seeds]}, #{options[:steps]} steps, " \
               "adversarial #{options[:adversarial]}"
        end

        def print_divergence(divergence)
          puts "-- #{divergence["field"]} --"
          divergence.except("field").each do |key, value|
            puts "#{key}: #{value.is_a?(String) ? value : JSON.generate(value)}"
          end
          puts
        end

        def print_shrunk(report, steps, shrunk)
          return unless shrunk

          puts "shrunk:      #{steps.size} -> #{shrunk.size} step(s) — #{relative(report[:steps_file])}"
          puts "replay:      #{replay_line(report)}"
          shrunk.each_with_index do |step, index|
            kind = %w[verb query dry_run].find { |key| step.key?(key) }
            puts "  #{index}: #{"#{kind} " unless kind == "verb"}#{step[kind]}  args: #{JSON.generate(step["args"])}"
          end
        end

        def replay_line(report)
          if report[:binary]
            "hecks check_conformance #{report[:dir]} script=#{report[:steps_file]} " \
              "artifact=#{report[:binary]}"
          else
            "hecks run #{report[:dir]} #{report[:steps_file]}"
          end
        end

        def report(counts, findings)
          puts
          puts "generated domains: #{counts[:clean]} clean, #{counts[:found]} found something, " \
               "#{counts[:invalid]} invalid, #{counts[:error]} errored"
          findings.each { |finding| print_finding(finding) }
          exit_status(counts, findings)
        end

        def exit_status(counts, findings)
          return EXIT_FOUND if findings.any?

          counts[:clean].zero? ? EXIT_ERROR : EXIT_OK
        end
      end
    end
  end
end
