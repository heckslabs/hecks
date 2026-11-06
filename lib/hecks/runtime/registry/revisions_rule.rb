module Hecks
  module Runtime
    class Registry
      # The revisions check a loaded hecksagon owes: `revisions true` needs a persistence
      # adapter that can hold them. Mixed into {Verification}.
      module RevisionsRule
        # `revisions true` keeps schema revisions in Postgres only; on any other adapter it would
        # silently keep none, so the boot refuses it and names the adapters that can hold them.
        REVISIONS_ADAPTERS = %w[Postgres].freeze

        private

        def refuse_revisions_on_other_adapter!(hecksagon)
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
