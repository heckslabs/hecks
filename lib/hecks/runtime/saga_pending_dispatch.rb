module Hecks
  module Runtime
    # Marks a checkpointed saga leg whose dispatch may not have run (persisted in `memory`).
    # Reported, never redriven: dispatch isn't idempotent, so a replay could double-apply.
    SAGA_PENDING_DISPATCH_KEY = :__hecks_saga_pending_dispatch__
  end
end
