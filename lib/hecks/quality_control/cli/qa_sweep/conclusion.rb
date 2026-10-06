# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # How a single-target sweep ends: a report and exit 2 on a finding, or a concluded sweep and a
      # released target when every seed held.
      module Conclusion
        private

        # Reads the sticky per-check `ever_surprised` bit rather than a loop's local, so a surprise
        # resolved before concluding never reads as clean. `&.` because rows logged before that
        # attribute existed lack the key; missing means no sticky surprise.
        def sweep_was_clean?(sweep)
          sweep.checks.none? { |c| c[:ever_surprised]&.[](:value) == "yes" }
        end

        # Decays the target's yield_score, adds this period's finds, and moves the streak (see
        # `Target.Release`).
        def release_target!(target, capabilities, current_streak, surprises:, clean:)
          next_yield_score = Hecks::Fuzzing::RotationPriority.next_yield_score(
            old_score: target.yield_score.value, surprises_this_period: surprises
          )
          target.release!(now: { value: Time.now.to_i }, yield_score: { value: next_yield_score },
                          next_streak: { value: clean ? current_streak + 1 : 0 },
                          capabilities: { value: capabilities.join(",") })
        end

        def report_finding(surprise)
          print_finding(surprise)
          EXIT_FOUND_SOMETHING
        end

        # Reached only when every seed held; re-reads the sticky `ever_surprised` bit, not the
        # loop's local.
        def conclude_clean_sweep
          notes = clean_sweep_notes
          @sweep.conclude!(notes: { value: notes })
          trace("seed loop+conclude")

          target = release_target!(@target, @capabilities, @current_streak, surprises: 0, clean: sweep_was_clean?(@sweep))
          trace("release")

          puts
          puts "clean — #{@target_reference} concluded and released. clean_streak: #{@current_streak} -> " \
               "#{target.clean_streak.value}. capabilities: #{target.capabilities.value.inspect}"
          puts notes
          EXIT_OK
        end

        def clean_sweep_notes
          "domain=#{@target_reference} path=#{@target_path} mode=#{@mode} modes=#{@active_modes.join(",")} " \
            "capabilities=#{@capabilities.join(",")} feature=#{@feature} seeds=#{@seeds} " \
            "steps=#{@steps_per_sequence} adversarial=#{@adversarial} role_draw=#{@role_draw} " \
            "dry_run=#{@dry_run} — every seed held, no divergence or property violation found."
        end
      end
    end
  end
end
