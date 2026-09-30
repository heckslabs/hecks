# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # `--release`: a person puts a suspended target back. It concludes or abandons what was open
      # against the target, then releases it with the streak moved by what was found.
      module ReleaseMode
        private

        # `--release`: a person puts a suspended target back, concluding what was open against it.
        def release_suspended_target
          target = ::QualityControl::Target.find(@target_reference)
          abort "target #{@target_reference.inspect} vanished between being queried and being released" unless target
          unless %w[suspended held].include?(target.status)
            abort "target #{@target_reference.inspect} is #{target.status.inspect}, not suspended (or held) — " \
                  "nothing to release"
          end

          open_sweeps = query("Sweep.Sweeping").select { |row| row[:target] == target.id }
                                               .map { |row| ::QualityControl::Sweep.find(row[:reference][:value]) }
          surprises = 0
          clean = !open_sweeps.empty?
          open_sweeps.each do |sweep|
            surprises += query("Bug.FoundIn", sweep_id: { value: sweep.id }).size
            clean &&= sweep_was_clean?(sweep)
            close_open_sweep(sweep, surprises)
          end

          # No open sweep (a crash between claim and open): nothing was watched, so the streak
          # resets rather than incrementing.
          puts "no open sweep against #{@target_reference} — releasing with the streak reset" if open_sweeps.empty?

          capabilities = Hecks::Fuzzing::TargetCapabilities.infer(@domain_path, rust_dir: @rust_dir)
          was = target.status
          target = release_target!(target, capabilities, target.clean_streak.value, surprises: surprises, clean: clean)
          puts "released #{@target_reference} (was #{was}) — status #{target.status}, " \
               "clean_streak #{target.clean_streak.value}, yield_score #{target.yield_score.value}, " \
               "capabilities #{target.capabilities.value.inspect}"
          EXIT_OK
        end

        def close_open_sweep(sweep, surprises)
          if sweep.made.value.positive? || sweep.waived.value.positive?
            begin
              sweep.conclude!(notes: { value: @release_notes })
            rescue Hecks::Runtime::InvariantViolation => e
              abort "--notes was refused by Sweep.Conclude — #{e.message}"
            end
            puts "concluded #{sweep.id} (#{sweep.made.value} check(s), #{surprises} bug(s) logged against it so far)"
          else
            # Never made a check: `Sweep.Conclude` refuses it, so abandon it to leave `Sweeping`.
            sweep.abandon!
            puts "abandoned #{sweep.id} (it never made a check)"
          end
        end
      end
    end
  end
end
