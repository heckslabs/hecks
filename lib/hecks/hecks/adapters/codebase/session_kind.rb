# frozen_string_literal: true

require "hecks/roundhouse/adapters/metering/session_role"
require_relative "slot_queue"

module Hecks
  module Adapters
    module Codebase
      # The session kind a heavy job asks Signalbox's Response table under, read from the job's
      # environment only. A landing's or the push train's job is a `gate`. A session the pipeline
      # dispatched names itself `agent:run` ({SessionCaller}) and is counted as Roundhouse counts it
      # (coder, orchestrator, else helper). Any other caller (`ticker`, `idler`) and none is a
      # `person`, which runs in every band, so an unknown caller is never held or refused. The tier
      # is urgent for a job {SlotQueue} ranks as the train's or urgent.
      module SessionKind
        # The variable a dispatched session names itself in.
        CALLER = "HECKS_CALLER"

        module_function

        # @param base [#[]] the job's environment
        # @param job [String, nil] the heavy job's class
        # @return [Hash{Symbol => String}] `role:` and `tier:`
        def of(base, job = nil)
          priority = SlotQueue.priority_of(base, job)
          { role: gate?(base, job, priority) ? "gate" : caller_role(base[CALLER].to_s),
            tier: [SlotQueue::TRAIN, SlotQueue::URGENT].include?(priority) ? "urgent" : "normal" }
        end

        # @return [Boolean] whether the job is the train's or a landing's, whatever its urgency
        def gate?(base, job, priority)
          priority == SlotQueue::TRAIN || base[SlotQueue::KIND_MARK] == SlotQueue::LANDING_VALUE ||
            job == SlotQueue::LANDING_JOB
        end

        # @param caller [String] the job's `HECKS_CALLER`
        # @return [String] the dispatched agent's role, else `person`
        def caller_role(caller)
          agent, run = caller.split(":", 2)
          run.to_s.empty? ? "person" : Metering::SessionRole.by_agent(agent.to_s)
        end
      end
    end
  end
end
