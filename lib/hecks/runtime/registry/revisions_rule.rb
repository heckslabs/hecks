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

        # Refuses `revisions true` on a domain none of whose aggregates is bound to an adapter
        # that keeps revisions. A domain may keep some aggregates in Memory beside the ones it
        # keeps in Postgres; the word reaches the Postgres ones.
        #
        # @param hecksagon [Bluebook::Hecksagon] the hecksagon being verified
        # @return [void]
        # @raise [WiringError] naming the domain's adapters and the ones that keep revisions
        def refuse_revisions_on_other_adapter!(hecksagon)
          return unless hecksagon.revisions?

          adapters = bound_persistence_adapters(hecksagon.domain)
          return if adapters.empty? || adapters.intersect?(REVISIONS_ADAPTERS)

          raise WiringError,
                "#{hecksagon.domain} sets revisions, but its persistence adapter is #{adapters.join(", ")} — " \
                "revisions need one of #{REVISIONS_ADAPTERS.join(", ")}"
        end

        # The adapters a domain's aggregates resolve to, each named once, in aggregate order. An
        # aggregate left unbound is skipped: its own refusal comes when it is first used.
        #
        # @param domain [String] the domain's name
        # @return [Array<String>] empty for a domain with no bluebook or no bound aggregate
        def bound_persistence_adapters(domain)
          aggregates = bluebook(domain)&.aggregates || []
          aggregates.filter_map { |aggregate| resolved_adapter_name(domain, aggregate) }.uniq
        end

        def resolved_adapter_name(domain, aggregate)
          Ports::Persistence::BindingPolicy.resolve(self, domain, aggregate).adapter.to_s
        rescue WiringError
          nil
        end
      end
    end
  end
end
