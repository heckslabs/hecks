# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module Checks
        # One seed of a sweep: the generated step list, and a check per active mode over it.
        module Seeds
          private

          def check_for(mode, feature, seed, shape, divergences)
            { mode:        mode,
              subject:     "[#{mode}] #{feature} fuzz seed #{seed} (#{shape})",
              expectation: MODE_EXPECTATIONS.fetch(mode),
              divergences: divergences,
              clean:       divergences.empty?,
              observation: divergences.empty? ? "held" : "diverged on: #{divergences.map { |d| d[:field] }.join(", ")}" }
          end

          # Extra `generate` arguments a guided seed needs in its `reproduce:` line; empty when
          # unguided.
          def plan_arguments(plan)
            return "" unless plan

            parts = []
            parts << "prefix: #{plan.prefix.inspect}" if plan.prefix
            parts << "favor: #{plan.favor.inspect}" unless plan.favor.empty?
            parts.empty? ? "" : ", #{parts.join(", ")}"
          end

          # Runs one seed under every active mode: `{ steps:, trace:, checks: }`, one check per
          # mode; logging is the loop's job. A generator crash is a finding too: a step broke the
          # interpreter before replay.
          def run_one_seed(seat, seed)
            plan = @campaign&.plan(seed)
            shape = seed_shape(plan)
            trace = generate_trace(seed, plan)
            return { plan: plan, steps: [], checks: [generator_crash_check(seed, shape, trace)] } if trace.is_a?(StandardError)

            outcomes = seed_outcomes(seat, trace.steps)
            { plan: plan, steps: trace.steps, trace: trace,
              checks: outcomes.map { |mode_key, divergences| check_for(mode_key, @feature, seed, shape, divergences) } }
          end

          def seed_shape(plan)
            shape = "#{@steps_per_sequence} steps, adversarial #{@adversarial}, role_draw #{@role_draw}, " \
                    "dry_run #{@dry_run}"
            plan&.spliced? ? "#{shape}, spliced" : shape
          end

          # @return [Object, StandardError] the generated trace, or the error the generator raised
          def generate_trace(seed, plan)
            Hecks::Fuzzing::SequenceGenerator.trace(
              @domain_path, seed: seed, steps: @steps_per_sequence, adversarial: @adversarial,
                            role_draw: @role_draw, dry_run: @dry_run, **(plan ? plan.generator_options : {})
            )
          rescue StandardError => e
            e
          end

          def generator_crash_check(seed, shape, error)
            { mode: :generator, subject: "[generator] #{@feature} fuzz seed #{seed} (#{shape}) — sequence generation",
              expectation: "SequenceGenerator builds every step without anything but a domain refusal escaping " \
                           "its own inline dispatch",
              divergences: [{ field:  "generator_crash",
                              detail: "#{error.class}: #{error.message}\n#{error.backtrace.first(6).join("\n")}" }],
              clean: false, observation: "generator crashed: #{error.class}: #{error.message}" }
          end

          def seed_outcomes(seat, steps)
            case seat
            when :differential then diff_ruby_vs_rust(@differ, @domain_path, steps, @binary, modes: @active_modes)
            when :persistence_parity
              { persistence_parity: persistence_parity_outcome(@domain_path, steps, @parity_database,
                                                               @parity_schema).last }
            when :concurrency
              { concurrency: concurrency_outcome(@domain_path, steps, @concurrency_database, @race_schema,
                                                 @reference_schema) }
            else ruby_only_outcome(@domain_path, steps, modes: @active_modes)
            end
          end
        end
      end
    end
  end
end
