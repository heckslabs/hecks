module Hecksagain
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
require_relative "driven/heki"
require_relative "driven/prism"
require_relative "driven/folder"
require_relative "driven/d1"
require_relative "driven/mock_stripe_adapter"
require_relative "driven/secure_random_identity"
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
