# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaMainGate
      # The sweep a red run of the gate on main is written as. Main is not a bluebook, so the sweep
      # runs
      # against one standing target, `main-gate`, that is shelved: the rotation never claims it.
      # Each gate
      # check is one `Check`, its expectation written before the answer is read.
      module Sweeping
        TARGET = "main-gate"
        ENGINEER = "qa_main_gate"

        private

        # @return [void] opens the target if no run has yet
        def standing_target
          return if ::QualityControl::Target.find(TARGET)

          target = ::QualityControl::Target.identify!(reference: { value: TARGET }, path: { value: @root })
          target.shelve!(reason: { value: "the quick gate on main is not a bluebook; this target only holds its sweeps" })
        end

        # @return [Object] the sweep of this commit's red run, concluded once every check is written
        def record_sweep(sha, results)
          standing_target
          sweep = ::QualityControl::Sweep.open!(target: TARGET, reference: { value: "MAIN-#{sha[0, 12]}" },
                                                engineer: { value: ENGINEER })
          results.each { |result| record_check(sweep, result, sha) }
          sweep.conclude!(notes: { value: "the quick gate on main at #{sha[0, 7]}: #{results.count { |r| !r.passed }} red" })
          sweep
        end

        def record_check(sweep, result, sha)
          sweep.check!(subject:     { value: "gate:#{result.id}" },
                       expectation: { value: "#{result.title} exits 0 on main at #{sha[0, 7]}" })
          sequence = ::QualityControl::Sweep.find(sweep.id).made.value
          settle(sweep, sequence, result)
        end

        def settle(sweep, sequence, result)
          if result.passed
            dispatch("QualityControl::Sweep.Check.Held", id: sweep.id, sequence: { value: sequence },
                                                          observation: { value: "exit 0" })
          else
            # Not `Check.Surprised`: its `SuspendOnSurprise` policy can only suspend a held target,
            # and this
            # one is shelved, so the policy would be refused on every red run. The red is carried by
            # the
            # `MainCheck` record and the bugs logged from the output.
            dispatch("QualityControl::Sweep.Check.Unsettled", id: sweep.id, sequence: { value: sequence },
                                                               observation: { value: result.output })
          end
        end

        def dispatch(name, **args)
          @runtime.dispatch_flat(name, args)
        end
      end
    end
  end
end
