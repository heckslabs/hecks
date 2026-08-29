module Hecks
  module Adapters
    # The driven side — every store or reader an adapter declaration can
    # bind. A small adapter is one file beside this one; sqlite, postgres
    # and heki keep a directory for their supporting cast. Each `.adapter`
    # file alongside is the DSL declaration the grammar bootstrap and the
    # Folder adapter load as data.
  end
end

require_relative "driven/memory"
require_relative "driven/sqlite"
require_relative "driven/postgres"
# `PostgresEra` is NOT `require_relative`d here — ADR 0033 moved it, and
# the rest of the era/lineage/translation subsystem, behind a loadable
# persistence plugin (`hecks/ports/persistence/plugins/era`) rather than
# requiring every app to carry it whether or not anything ever binds
# `persisted_by "PostgresEra"`. `Module#autoload` is the one-line seam
# that makes that genuinely load-nothing-until-asked instead of pushing
# an explicit `require` onto every one of the ~15 generic `bin/*` tools
# that boot an arbitrary checked-in domain (several of which — pizzas,
# compliance, chess, roster — bind PostgresEra): the FIRST real
# `Adapters.const_get("PostgresEra")` (`registry/verification.rb`'s own
# adapter resolution, unchanged) transparently `require`s the plugin
# entry point, which defines the constant AND calls `register_plugin`
# as its own side effect (`plugins/era.rb`'s last line) — the exact
# same effect an explicit `require "hecks/ports/persistence/plugins/
# era"` has, just deferred to the moment something is actually asked
# for `PostgresEra` rather than sprinkled across every caller that
# might. A domain that never binds it never triggers the autoload, so
# never loads a line of era code — unchanged from ADR 0033's own goal.
Hecks::Adapters.autoload(:PostgresEra, "hecks/ports/persistence/plugins/era")
require_relative "driven/lambda"
require_relative "driven/heki"
require_relative "driven/local_storage"
require_relative "driven/prism"
require_relative "driven/folder"
require_relative "driven/d1"
require_relative "driven/mock_stripe_adapter"
require_relative "driven/secure_random_identity"
require_relative "driven/system_clock"
# `SequentialIdentity` — the deterministic identity_generation test
# double — is NOT required here on purpose. It lives at
# spec/fixtures/sequential_identity.{adapter,rb}, loaded explicitly by
# whichever spec wants it: this file's `require_relative` list is what
# `Folder#load_library`'s `.adapter` glob backs, and `.adapter` DSL
# declarations register into every registry any real `Hecks.boot` ever
# builds. Two adapters answering `identity_generation` unconditionally
# would make the port permanently ambiguous — `Ports::IdentityGeneration
# .adapter` refuses to choose between more than one — for every
# consumer, forever, not just specs that want the deterministic one.
require_relative "driven/governance_authorization"
require_relative "driven/identity_registry"
require_relative "driven/google_authentication"
require_relative "driven/claude_code"
