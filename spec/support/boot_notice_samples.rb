# The three boot notices a refusal must not open with, and a real refusal to put them before.
module BootNoticeSamples
  def saga
    "[hecks] QualityControl declares process_manager(s) BugCiWatch but its resolved " \
      "persistence adapter has no save_saga — state is LOST on restart"
  end

  def outbox
    "[hecks] outbox row 08d7cc74/policy:Hecks::ReadTheJob was claimed before the last " \
      "crash/restart and never settled"
  end

  def overlay
    "hecks: this worktree lacks lib/hecks/hecks/hecks.local.hecksagon from the main checkout"
  end

  def refusal = "RegenerationRefused: confirm.value=true is needed to write"

  def notices = [saga, outbox, overlay]
end
