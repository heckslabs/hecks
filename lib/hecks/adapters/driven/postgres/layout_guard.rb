require_relative "../../../indifferent_key"
require_relative "../../../runtime/errors"

module Hecks
  module Adapters
    class Postgres
      # The guard a table-layout boot owes a database that already keeps the domain's revisions
      # (ADR 0182). Booting the table layout there would create an empty table beside the domain's
      # eras and read none of its history, so the boot refuses and names the hecksagon word.
      # Mixed into {Postgres}; the revision layout needs no guard of its own, because the revision
      # store already refuses a database that holds no era for the domain.
      module LayoutGuard
        ERAS_TABLE = "hecks_eras".freeze

        private

        def refuse_revision_database!
          return unless eras_held_for?(layout_domain)

          raise Runtime::WiringError,
                "#{layout_domain} keeps its revisions in this database (#{ERAS_TABLE} holds its eras), but " \
                "its hecksagon binds Postgres without `revisions true`, which would start an empty table " \
                "and read none of that history. Add `revisions true` to the hecksagon."
        end

        def eras_held_for?(domain)
          return false unless pg_exec_params("SELECT to_regclass($1) AS found", [ERAS_TABLE])[0]["found"]

          pg_exec_params("SELECT 1 FROM #{ERAS_TABLE} WHERE domain = $1 LIMIT 1", [domain]).ntuples.positive?
        end

        # The domain a revision store would journal this aggregate under: the binding's own `domain`
        # setting, else the bluebook that owns the aggregate, else its storage name.
        def layout_domain
          (IndifferentKey.read(@settings, :domain) || owner_name || @aggregate.storage_name).to_s
        end

        def owner_name
          owner = @aggregate.hecks_owner
          owner&.name
        end
      end
    end
  end
end
