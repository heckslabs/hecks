require_relative "observation"
require_relative "read_only_steps"

module Hecks
  module Fuzzing
    module Replay
      # One replay in flight: plays steps against a booted runtime and accumulates the
      # observable history, including the oracle traces `Properties` check.
      #
      # The oracle snapshots taken around each dispatch are timed relative to it; the order in
      # which `take_marks` and `dispatch` run them is part of what they mean.
      class Session
        include ReadOnlySteps
        include Observation

        # What is read before a dispatch so its own effects can be sliced out afterwards.
        #
        # `outbox_ids` is a set of delivery_ids, not a size, because `runtime.outbox.rows`
        # concatenates several stores' own arrays, so a plain "grew from N to M" tail slice
        # could miss or misattribute rows once more than one repository has an outbox.
        Marks = Struct.new(:reaction, :saga, :outbox_ids, :fan_out_snapshot, :guard_check, :mutation_trace, :role_check)

        # @param runtime [Hecks::Runtime] a freshly booted runtime
        def initialize(runtime)
          @runtime         = runtime
          @refusals        = []
          @queries         = []
          @dry_runs        = []
          @dry_run_traces  = []
          @fan_outs        = []
          start_checks
          @mutation_traces = []
          @outbox_traces   = []
          @fan_out_targets = fan_out_targets
        end

        # Plays every step in order.
        #
        # @param steps [Array<Hash>] the step list
        # @return [Session] self
        def play(steps)
          steps.each { |step| play_step(step) }
          self
        end

        # The history of everything played so far, with the booted chapter beside it so
        # properties.rb's lifecycle/saga checks have the declared IR. `bluebook:` (singular) is
        # the first-loaded chapter; `bluebooks:` (plural) is the full domain-name-keyed map, for
        # a property that must resolve a verb back to its declaring bluebook.
        #
        # `runtime` is still live here, so SelfConsistency runs against the same registry a
        # second boot couldn't reuse.
        #
        # @param self_consistency [Boolean] also run SelfConsistency.check
        # @return [Hash] instances, events, refusals, reactions, sagas, queries, oracle traces
        def history(self_consistency: false)
          history = observed_history
          history[:self_consistency] = SelfConsistency.check(@runtime, history) if self_consistency
          history
        end

        private

        # The two checks recorded before a dispatch and compared with its outcome afterwards.
        def start_checks
          @guard_checks = []
          @role_checks  = []
        end

        def play_step(step)
          step = step.transform_keys(&:to_s)
          args = (step["args"] || {}).transform_keys(&:to_sym)

          if (question = step["query"])
            ask(question, args)
          elsif (hypothetical = step["dry_run"])
            dry_run(step, hypothetical, args)
          else
            dispatch(step, args)
          end
        end

        def dispatch(step, args)
          marks = take_marks(step, args)

          # `role:`/`actor_id:` are optional per-step keys; a step with neither
          # dispatches bare, as every existing corpus step always has. Binds the
          # ambient caller for exactly this one dispatch, then unbinds, so
          # back-to-back steps with different (or no) `role:` never leak into each other.
          result = Replay.as_step_caller(step) { @runtime.dispatch_flat(step["verb"], args) }
          record_effects(step, result, marks)
        rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
          record_refusal(step, e, marks&.guard_check, marks&.role_check)
        end

        # Taken before dispatch, so this step's own reactions, sagas and outbox rows can be
        # sliced out after and matched against an independent recomputation. The fan-out
        # snapshot is what a `for_each` query would have seen: `deliver_for_each` runs its
        # query synchronously inside this same dispatch, so reading the live repository
        # after would see what the fan-out's own dispatched commands already mutated, not what
        # it matched. The guard is replayed read-only before the real dispatch can mutate
        # anything a cross-aggregate given dereferences, and the entity element a mutation
        # step's args address is snapshotted so it can be diffed against its post-dispatch state.
        def take_marks(step, args)
          Marks.new(@runtime.reactions.size, @runtime.sagas.size, @runtime.outbox.rows.map(&:delivery_id),
                    fan_out_snapshot, GuardCheck.build(@runtime, step["verb"], args),
                    MutationTrace.build(@runtime, step["verb"], args), RoleCheck.build(@runtime, step))
        end

        def record_effects(step, result, marks)
          @fan_outs.concat(Replay.fan_out_findings(@runtime, marks.fan_out_snapshot, result.events,
                                                   @runtime.reactions[marks.reaction..]))
          record_outbox(step, marks)
          record_accepted_checks(marks)
          record_mutation(marks.mutation_trace) if marks.mutation_trace
        end

        # An accepted dispatch: the guard let it through and the role gate did not refuse it.
        def record_accepted_checks(marks)
          @guard_checks << marks.guard_check.merge(actual_refused: false, actual_kind: nil) if marks.guard_check
          @role_checks << marks.role_check.merge(outcome: nil) if marks.role_check
        end

        # Every outbox row this step's own dispatch newly wrote, across every
        # bound repository including any a reaction cascade touched, paired with
        # the reaction/saga rows that same dispatch produced. Skipped when empty.
        def record_outbox(step, marks)
          new_rows = outbox_rows_since(marks)
          return if new_rows.empty?

          @outbox_traces << { verb: step["verb"], rows: new_rows.map(&:to_h),
                              reactions: @runtime.reactions[marks.reaction..].dup,
                              sagas: @runtime.sagas[marks.saga..].dup }
        end

        def outbox_rows_since(marks)
          @runtime.outbox.rows.reject { |row| marks.outbox_ids.include?(row.delivery_id) }
        end

        # After — only on success; a refused step mutated nothing, so there is no "after" to
        # compare (and `MutationTrace.build` already skipped anything with no mutations to
        # trace in the first place).
        def record_mutation(mutation_trace)
          @mutation_traces << mutation_trace.merge(after: MutationTrace.read_after(@runtime, mutation_trace))
        end

        # `kind:` is the raised class, not derived from the message: several
        # refusal templates share the same wording, so only the class tells a
        # guard refusal apart from the rest.
        #
        # Only a refusal raised by the guard itself counts for the guard check. A refusal from a
        # stage before or after enforce_givens can share TypeMismatch's class, so
        # anything outside the two guard classes is left out — inconclusive, not a pass.
        #
        # A role check records the refusal's class whatever it is, since the property decides which
        # outcomes are conclusive: a refusal before the role gate says nothing about the grant.
        def record_refusal(step, error, guard_check, role_check)
          @refusals << { verb: step["verb"], error: error.message, kind: Replay.refusal_kind(error) }
          @role_checks << role_check.merge(outcome: Replay.refusal_kind(error)) if role_check
          return unless guard_check && GUARD_REFUSAL_CLASSES.include?(error.class)

          @guard_checks << guard_check.merge(actual_refused: true, actual_kind: error.class.name)
        end
      end
    end
  end
end
