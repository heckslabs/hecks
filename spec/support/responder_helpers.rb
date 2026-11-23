# frozen_string_literal: true

# What the responder specs drive: a responder declared, replayed and switched on, and the stall a
# blocked fixer works on, closed before the fixer asks.
module ResponderHelpers
  def declare(family) = launch("responder.declare!", "family.value=#{family}", "spacing.value=3600", "--wait")

  def switch_on(family)
    declare(family)
    launch("responder.record_replay!", "to=#{family}", "--wait")
    launch("responder.switch_on!", "to=#{family}", "--wait")
  end

  def switch_on_refusal(family) = launch("responder.switch_on!", "to=#{family}", "--wait").join(" ")

  # The stall of a run, closed because its subject settled.
  def settle(stall)
    launch("stall_watch.detect!", "run.value=look-#{stall}", "--wait")
    launch("stall.abandon!", "watch=look-#{stall}", "stall.value=#{stall}", "reason.value=subject settled", "--wait")
  end
end
