module Hecks
  module Runtime
    class Registry
      # The revisions check a loaded hecksagon owes: `revisions true` needs a persistence
      # adapter that can hold them. Mixed into {Verification}.
      module RevisionsRule
        # `revisions true` keeps schema revisions in Postgres only; on any other adapter it would
        # silently keep none, so the boot refuses it and names the adapters that can hold them.
        REVISIONS_ADAPTERS = %w[Postgres PostgresEra].freeze

        private

        # `PostgresEra` is no longer a bindable adapter (ADR 0182): the revision layout is
        # `Postgres` with `revisions true`. The class stays, so the era tools can still reach it.
        def refuse_postgres_era_binding!(hecksagon)
          bound = hecksagon.binds.find { |bind| bind.adapter.to_s == "PostgresEra" }
          return unless bound

          raise WiringError,
                "#{hecksagon.domain} binds PostgresEra, which is no longer an adapter — bind Postgres " \
                "and write `revisions true` in the hecksagon for the same layout"
        end

        def refuse_revisions_on_other_adapter!(hecksagon)
          refuse_postgres_era_binding!(hecksagon)
          return unless hecksagon.revisions?

          bluebook_ir = bluebook(hecksagon.domain)
          anchor = bluebook_ir&.aggregates&.first
          return unless anchor

          bind = Ports::Persistence::BindingPolicy.resolve(self, hecksagon.domain, anchor)
          return if REVISIONS_ADAPTERS.include?(bind.adapter.to_s)

          raise WiringError,
                "#{hecksagon.domain} sets revisions, but its persistence adapter is #{bind.adapter} — " \
                "revisions need one of #{REVISIONS_ADAPTERS.join(", ")}"
        end
      end
    end
  end
end
