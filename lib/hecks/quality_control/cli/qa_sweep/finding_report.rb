# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # What a sweep prints when a check surprised: the header, the reproduction, every divergence
      # and the generated and shrunk steps, so an agent can decide from the report alone.
      module FindingReport
        private

        # @param surprise [Hash] the surprising seed's result: `seed`, `steps`, `checks`, `plan` and
        #   optionally `shrunk`
        # @return [void]
        def print_finding(surprise)
          print_finding_header
          print_finding_facts(surprise)
          # One block per surprised check, so a seed that surprised on two axes prints both.
          surprise[:checks].each { |check| print_surprised_check(check) }
          print_generated_steps(surprise[:steps])
          # One shrunk demonstration per shrinkable check, written to a file so the replay line
          # works as printed.
          Array(surprise[:shrunk]).each { |shrunk| print_shrunk(shrunk, surprise[:seed]) }
        end

        def print_finding_header
          puts
          puts "=" * 72
          puts "FOUND SOMETHING — sweep #{@sweep_reference} left OPEN, target #{@target_reference} SUSPENDED."
          puts "No Bug was logged (that needs a real failing-test demonstration, which"
          puts "needs judgment this script does not have — bin/qa_log_bug is the door)"
          puts "and the sweep was not concluded. The ledger's own SuspendOnSurprise"
          puts "policy took the target out of the rotation; it stays out until a PERSON"
          puts "runs: bin/qa_sweep #{@target_reference} --release --notes \"…\""
          puts "An agent decides from here: self-contained fix with a regression test"
          puts "and a PR (bin/qa_open_pr), or a Bug left open for something bigger."
          puts "Never waived here, never filed upstream from here."
          puts "=" * 72
          puts
        end

        def print_finding_facts(surprise)
          puts "domain:      #{@target_path} (#{@domain_path})"
          puts "target:      #{@target_reference}"
          puts "sweep:       #{@sweep_reference} (id #{@sweep.id})"
          puts "mode:        #{@mode} (active modes: #{@active_modes.join(', ')}; " \
               "capabilities: #{@capabilities.join(', ')})"
          puts "seed:        #{surprise[:seed] || 'n/a (once-per-sweep check)'}"
          puts "steps:       #{@steps_per_sequence}"
          puts "adversarial: #{@adversarial}"
          puts "role-draw:   #{@role_draw}"
          puts "dry-run:     #{@dry_run}"
          puts "streak:      clean_streak was #{@current_streak} going into this pass"
          if surprise[:seed]
            puts "reproduce:   Hecks::Fuzzing::SequenceGenerator.generate(#{@domain_path.inspect}, " \
                 "seed: #{surprise[:seed]}, steps: #{@steps_per_sequence}, adversarial: #{@adversarial}, " \
                 "role_draw: #{@role_draw}, dry_run: #{@dry_run}#{plan_arguments(surprise[:plan])})"
          end
          puts "surprised:   #{surprise[:checks].map { |c| c[:mode] }.join(', ')}"
          puts
        end

        def print_surprised_check(check)
          puts "subject:     #{check[:subject]}"
          puts "expectation: #{check[:expectation]}"
          puts "observation: #{check[:observation]}"
          puts

          # One generic printer for every divergence shape (ruby/rust, memory/postgres_era,
          # live/rehydrated): print every key except the field and the redundant
          # domain/aggregate/type.
          check[:divergences].each do |divergence|
            label = [divergence[:field], divergence[:domain], divergence[:aggregate], divergence[:type]]
                    .compact.join(" ")
            puts "-- #{label} --"
            divergence.except(:field, :domain, :aggregate, :type).each { |key, value| puts "#{key}: #{value.inspect}" }
            puts
          end
        end

        # Lists every step in order with its `adversarial` metadata, so a divergence's verb matches
        # back to its step and the Bug can name the mutation.
        def print_generated_steps(steps)
          puts "-- generated steps (index: verb, adversarial mutation if any) --"
          steps.each_with_index do |step, index|
            label = %w[verb query dry_run].filter_map { |key| step[key] if step.key?(key) }.first
            mutation = step["adversarial"] ? JSON.generate(step["adversarial"]) : "(not mutated)"
            puts "#{index}: #{label}  #{mutation}"
            puts "   args: #{JSON.generate(step['args'])}" if step["adversarial"]
          end
          puts
        end

        def print_shrunk(shrunk, seed)
          path = write_shrunk!(shrunk, seed)
          budget = shrunk[:exhausted] ? ", budget exhausted — may shrink further" : ""
          puts "shrunk:      [#{shrunk[:mode]}] #{shrunk[:original_size]} -> #{shrunk[:steps].size} step(s) " \
               "(#{shrunk[:attempts]} candidate checks#{budget})"
          puts "file:        #{path.delete_prefix("#{@root}/")}"
          replay =
            if %i[differential self_consistency].include?(shrunk[:mode]) && @binary
              "bin/rust_conformance #{@domain_path} #{path} #{@binary}"
            else
              "bin/run #{@domain_path} #{path}"
            end
          puts "replay:      #{replay}"
          puts "-- shrunk steps [#{shrunk[:mode]}] --"
          shrunk[:steps].each_with_index do |step, index|
            kind = %w[verb query dry_run].find { |key| step.key?(key) }
            puts "#{index}: #{"#{kind} " unless kind == 'verb'}#{step[kind]}  args: #{JSON.generate(step['args'])}"
          end
          puts
        end
      end
    end
  end
end
