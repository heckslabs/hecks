require_relative "../errors"
require_relative "../boot_gates"
require_relative "../../ports/persistence"

module Hecks
  module Runtime
    class Loader
      # The steps a boot takes between loading a domain's files and binding its dispatcher: the
      # boot gates, the adapters a bind names, and the privacy markings to dispatch. Extended onto
      # {Loader}, whose class methods these become.
      module BootSteps
        # Turns every `.hecksagon`-declared `mark_sensitive` fact into a real
        # `Privacy::Marking.Mark`. Idempotent across reboots — a marking already
        # present is never re-dispatched. A no-op when nothing declared one, or
        # the domain never attached Privacy at all.
        def seed_privacy_markings!(dispatcher, registry)
          return if registry.pending_privacy_markings.empty?

          provider = registry.provider_of(Bluebook::Capabilities::PRIVACY)
          return unless provider

          already_marked = already_marked_by_domain(dispatcher, registry, provider)
          registry.pending_privacy_markings.each do |marking|
            next if already_marked[marking[:domain]].include?(marking[:attribute_path])

            dispatcher.dispatch_flat(provider.provided_verb(Bluebook::Capabilities::PRIVACY, :mark_sensitive), marking)
          end
        end

        # Each domain with a pending marking, with the attribute paths Privacy already marks for it.
        def already_marked_by_domain(dispatcher, registry, provider)
          verb = provider.provided_verb(Bluebook::Capabilities::PRIVACY, :markings_for)
          domains = registry.pending_privacy_markings.map { |marking| marking[:domain] }.uniq
          domains.to_h do |domain|
            [domain, dispatcher.query(verb, domain: domain).map { |row| row[:attribute_path][:value] }]
          end
        end

        # Runs every registered boot gate against `registry`, in order:
        # era-checking (if a plugin contributes one) before `verify!`, saga
        # rehydration after. No era-specific class is named here — each loaded
        # persistence plugin contributes its own gates generically (ADR 0031).
        def run_boot_gates!(registry, directory, open_stores: true)
          gates = BootGates.new
          # Before any adapter loads: a binding to a removed adapter is refused by name.
          registry.refuse_retired_adapters!
          load_bound_adapters!(registry)
          Ports::Persistence.each_plugin { |plugin| plugin.contribute_boot_gates(registry, gates) }

          gates.run!(:pre_verify, registry, directory)
          registry.verify!(open_stores: open_stores)

          gates.register(:saga_rehydration, ->(reg, _dir) { reg.rehydrate_sagas! }, phase: :post_verify) if
            open_stores && registry.saga_domains.any? { |domain| registry.saga_durable?(domain) }
          gates.run!(:post_verify, registry, directory)
          gates
        end

        # Resolves the Ruby implementation of every adapter a hecksagon binds, and of every
        # `default_adapter` a world names (a bluebook that binds nothing takes its world's), in the
        # layout the domain's hecksagon picks (`revisions true` picks Postgres's revision layout).
        # A layout's implementation can register its own persistence plugin as a side effect of
        # loading (the revision layout registers the era plugin) — resolving here, before gates
        # are collected, is what registers those plugins' gates without the app requiring them
        # itself. A bind with no implementation is left for `verify!` to refuse.
        def load_bound_adapters!(registry)
          (bound_adapters(registry) + default_adapters(registry)).uniq.each do |domain, name|
            load_adapter(registry, domain, name)
          end
        end

        private

        # Each domain paired with every adapter its hecksagon binds.
        def bound_adapters(registry)
          registry.hecksagons.each_value.flat_map do |hecksagon|
            hecksagon.binds.map { |bind| [hecksagon.domain, bind.adapter] }
          end
        end

        # Each domain paired with the `default_adapter` its world names, where it names one.
        def default_adapters(registry)
          naming = registry.worlds.values.select(&:default_adapter)
          naming.map { |world| [world.domain, world.default_adapter] }
        end

        def load_adapter(registry, domain, name)
          Ports::Persistence::Layout.adapter_class(registry, domain, name)
        rescue WiringError
          nil
        end
      end
    end
  end
end
