require_relative "../../../../../indifferent_key"

module Hecks
  module Adapters
    class PostgresEra
      # The steps `PostgresEra#initialize` runs after joining the shared connection: naming the
      # journal, resolving the era, and provisioning every table the adapter reads or writes.
      module Boot
        private

        # Journal name: the owning bluebook's declared name, matching the key rust/host derives its
        # advisory lock from (ADR 0036). A bare aggregate with no owner falls back to its own name.
        def journal_domain(aggregate, settings)
          self.class.setting(
            settings, :domain, default: aggregate.hecks_owner&.name || aggregate.storage_name
          ).to_s
        end

        # Coalesce instead of `setting` for the era: the factory always passes `era:`, nil until
        # the boot gate resolves it, and nil can never be a real override.
        def resolve_era!(settings)
          @era = IndifferentKey.read(settings, :era)
          @era ||= @lineage.current_era
          # Non-nil only for a held-but-superseded boot. `append` and `atomic_put` refuse on it
          # because a superuser walks through the RLS fence.
          @superseded_by = IndifferentKey.read(settings, :superseded_by)
        end

        def provision!
          # Idempotent self-healing against any boot-ordering surprise.
          @lineage.ensure_head_snapshot!(table, @era)
          @lineage.ensure_first_head!(table) if @era == 1
          # One row-cache table per where-field the aggregate's queries use; `query` consults it
          # to skip the head reduction.
          @field_caches = ensure_field_caches!
          create_event_table!
          create_saga_table!
          create_outbox_table!
        end
      end
    end
  end
end
