module Hecks
  # The driven side: every store or reader an adapter declaration can bind.
  module Adapters
  end
end

require_relative "driven/memory"
require_relative "driven/sqlite"
require_relative "driven/postgres"
# PostgresEra lives in a persistence plugin, autoloaded so a domain that never binds
# it loads no era code; the plugin entry point registers itself on load (ADR 0033).
Hecks::Adapters.autoload(:PostgresEra, "hecks/ports/persistence/plugins/era")
require_relative "driven/lambda"
require_relative "driven/heki"
require_relative "driven/local_storage"
require_relative "driven/prism"
require_relative "driven/folder"
require_relative "driven/d1"
require_relative "driven/mock_stripe_adapter"
require_relative "driven/tenant_provisioner"
require_relative "driven/secure_random_identity"
require_relative "driven/in_process_key_vault"
require_relative "driven/system_clock"
# SequentialIdentity (spec/fixtures) is deliberately not required here: a second
# `identity_generation` adapter would make that port ambiguous for every boot.
require_relative "driven/governance_authorization"
require_relative "driven/identity_registry"
require_relative "driven/google_authentication"
require_relative "driven/claude_code"
