require_relative "constants"
require_relative "../../runtime/errors"

module Hecks
  module Ports
    module Persistence
      # The storage layout a persistence adapter builds for a domain, chosen in the domain's
      # hecksagon (ADR 0182). An adapter whose class answers `layout_class` keeps more than one
      # layout: `Postgres` keeps one table per aggregate unless the hecksagon says
      # `revisions true`, and then keeps the revision layout. Every other adapter has one layout,
      # its own class.
      module Layout
        module_function

        # The settings only the revision layout reads. A world that gives one to a domain on the
        # table layout would believe it had revisions it does not have, so `refuse_table_settings!`
        # refuses it.
        REVISION_SETTINGS = %i[formerly allow_superuser mint_eras disposable_ledger mints_era].freeze

        # Whether a domain keeps schema revisions: its own hecksagon says `revisions true`, or a
        # hecksagon that attaches it says so and hands it its root `persisted_by` default.
        #
        # @param registry [Runtime::Registry] the registry holding every hecksagon
        # @param domain [String, Symbol, nil] the domain's name; nil answers false
        # @return [Boolean]
        def revisions?(registry, domain)
          return false if domain.nil?
          return true if registry.hecksagon(domain)&.revisions?

          registry.hecksagons.each_value.any? do |hecksagon|
            hecksagon.revisions? && hecksagon.attaches?(domain) && hecksagon.default_binds(VERB).any?
          end
        end

        # The class that keeps a domain's rows for the named adapter, in the layout its hecksagon
        # chose.
        #
        # @param registry [Runtime::Registry] the registry the adapter is declared in
        # @param domain [String, Symbol, nil] the domain the adapter serves
        # @param adapter_name [String] the adapter's declared name, such as `"Postgres"`
        # @return [Class] the adapter's class, or the class of the layout it picks
        # @raise [Runtime::WiringError] if no Ruby class implements the adapter
        def adapter_class(registry, domain, adapter_name)
          klass = registry.adapter_class(adapter_name)
          return klass unless klass.respond_to?(:layout_class)

          klass.layout_class(revisions: revisions?(registry, domain))
        end

        # Whether a domain's adapter keeps layouts and was left on its table layout.
        #
        # @param registry [Runtime::Registry] the registry the adapter is declared in
        # @param domain [String, Symbol, nil] the domain the adapter serves
        # @param adapter_name [String] the adapter's declared name
        # @return [Boolean] false for an adapter with one layout, or one with no Ruby class
        def table_layout?(registry, domain, adapter_name)
          klass = registry.adapter_class(adapter_name)
          klass.respond_to?(:layout_class) && !revisions?(registry, domain)
        rescue Runtime::WiringError
          false
        end

        # Refuses a revision-only setting a world gives a domain left on the table layout.
        #
        # @param registry [Runtime::Registry] the registry the adapter is declared in
        # @param domain [String, Symbol] the domain the adapter serves
        # @param adapter_name [String] the adapter's declared name
        # @param settings [Hash{Symbol, String => Object}] the settings its world declares
        # @return [void]
        # @raise [Runtime::WiringError] naming the settings, when the table layout was chosen
        def refuse_table_settings!(registry, domain, adapter_name, settings)
          given = settings.keys.map(&:to_sym) & REVISION_SETTINGS
          return if given.empty? || !table_layout?(registry, domain, adapter_name)

          raise Runtime::WiringError,
                "#{domain} binds #{adapter_name} without revisions, but its world sets " \
                "#{given.map(&:inspect).join(", ")}, which only the revision layout reads. " \
                "Add `revisions true` to #{domain}'s hecksagon, or remove the setting from the world."
        end
      end
    end
  end
end
