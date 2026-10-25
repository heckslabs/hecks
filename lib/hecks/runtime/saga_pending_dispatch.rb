module Hecks
  module Runtime
    # Marks a checkpointed saga leg whose dispatches may not all have settled (persisted in
    # `memory`). The marker records how many settled and whether the next was started, so the
    # boot redrive delivers the ones that never began, and the one that may have run only when
    # its store dedupes by dispatch key or its command is declared idempotent.
    SAGA_PENDING_DISPATCH_KEY = :__hecks_saga_pending_dispatch__
  end
end
