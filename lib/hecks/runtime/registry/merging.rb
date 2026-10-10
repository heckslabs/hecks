module Hecks
  module Runtime
    class Registry
      # Folds a later `.hecksagon` or `.world` for a domain into the one already registered, so a
      # base file plus an environment overlay both take effect.
      module Merging
        # Concatenates every list-shaped fact from base and overlay. `binds` is additive too:
        # an overlay rebinding an aggregate is meant to shadow the base's bind at resolution
        # time, not erase it — `Ports::Persistence::BindingPolicy.resolve`'s "exactly one
        # authoritative bind" check is what actually catches a genuine double-bind.
        #
        # @param base [Bluebook::Hecksagon] the domain's already-registered wiring
        # @param overlay [Bluebook::Hecksagon] the newly loaded block's own wiring to
        #   fold in
        # @return [Bluebook::Hecksagon] a new wiring with every list-shaped fact
        #   concatenated, `base` then `overlay`
        def merge_hecksagons(base, overlay)
          # Order-independent: list facts uniq, so loading context_map before or after the
          # domain file yields the same merged hecksagon.
          lists = %i[subscriptions attachments translates driving].to_h do |facet|
            [facet, (base.public_send(facet) + overlay.public_send(facet)).uniq]
          end
          Bluebook::Hecksagon.new(domain: base.domain, binds: base.binds + overlay.binds,
                                  bounded: base.bounded? || overlay.bounded?, **lists)
        end

        # Scalars (`realm`, `latest`, `default_database`, `default_adapter`): the overlay's
        # value wins when present, else the base's survives. `settings` is a shallow merge
        # keyed by verb (and `"verb:adapter"`); an overlay key replaces the base's whole
        # resolved hash for that key, it does not deep-merge within it.
        #
        # @param base [Bluebook::World] the domain's already-registered world
        # @param overlay [Bluebook::World] the newly loaded block's own world to fold in
        # @return [Bluebook::World] a new world with `overlay`'s scalars winning when
        #   present, and `settings` shallow-merged, `overlay`'s keys winning
        def merge_worlds(base, overlay)
          Bluebook::World.new(
            domain:           base.domain,
            realm:            overlay.realm || base.realm,
            latest:           overlay.latest || base.latest,
            settings:         base.settings.merge(overlay.settings),
            default_database: overlay.default_database || base.default_database,
            default_adapter:  overlay.default_adapter || base.default_adapter
          )
        end
      end
    end
  end
end
