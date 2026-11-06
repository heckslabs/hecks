module Hecks
  module Runtime
    class Registry
      # The revisions check a loaded hecksagon owes: `revisions true` needs a persistence
      # adapter that can hold them. Mixed into {Verification}.
      module RevisionsRule
        # `revisions true` keeps schema revisions in Postgres only; on any other adapter it would
        # silently keep none, so the boot refuses it and names the adapters that can hold them.
        REVISIONS_ADAPTERS = %w[Postgres].freeze

        # The retired `postgres_era` key (ADR 0182): the revision layout is `postgres` with
        # `revisions true`. Named so the boot says what to write instead of "unknown adapter".
        RETIRED_ERA_KEYS = %w[postgres_era PostgresEra].freeze

        private

        def refuse_retired_era_key!(hecksagon)
          bound = hecksagon.binds.find { |bind| RETIRED_ERA_KEYS.include?(bind.adapter.to_s) }
          return unless bound

          raise WiringError,
                "#{hecksagon.domain} binds #{bound.adapter}, which was removed in 8.0 — bind postgres " \
                "and write `revisions true` in the hecksagon for the same layout"
        end

        def refuse_revisions_on_other_adapter!(hecksagon)
          refuse_retired_era_key!(hecksagon)
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
