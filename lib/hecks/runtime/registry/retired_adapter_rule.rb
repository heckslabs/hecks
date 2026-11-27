module Hecks
  module Runtime
    class Registry
      # The check for a retired adapter name: a hecksagon or a world that names one is refused at
      # boot, and so is any lookup of its class by that name, naming what replaced it. No alias is
      # kept, so a binding never reaches a layout it did not choose. Mixed into {DeclarationChecks}.
      module RetiredAdapterRule
        # Each removed adapter, by its name with case and underscores folded, and what replaced it.
        RETIRED = {
          "postgresera" => { name:        "PostgresEra",
                             replacement: 'persisted_by "Postgres" plus `revisions true` in the hecksagon (ADR 0182)' }
        }.freeze

        # What replaced a removed adapter, or nil for an adapter that was not removed.
        #
        # @param name [String, Symbol, nil] an adapter name, any case, with or without underscores
        # @return [Hash{Symbol => String}, nil] the removed adapter's `name` and its `replacement`
        def self.retired(name) = RETIRED[name.to_s.delete("_").downcase]

        # Refuses a lookup of a removed adapter's class by its name, so no path that resolves a
        # bound name reaches the class a removed adapter left behind (`AdapterNamespace.resolve`).
        #
        # @param name [String, Symbol] the adapter name being resolved
        # @return [void]
        # @raise [WiringError] naming the removed adapter and its replacement
        def self.refuse_lookup!(name)
          raise WiringError, refusal("Hecks", "an adapter lookup names", name) if retired(name)
        end

        # The refusal for a removed adapter, in the words the Rust host's
        # `retired_adapter_refusal` uses.
        #
        # @param domain [String] the domain, or `Hecks` for a lookup outside one
        # @param where [String] what named the adapter, such as `its hecksagon binds`
        # @param name [String] the removed adapter's name as it was written
        # @return [String]
        def self.refusal(domain, where, name)
          retired = retired(name)
          "#{domain}: #{where} #{name}, which Hecks 8.0 removed. Write #{retired[:replacement]} " \
            "instead: #{retired[:name]} is now Postgres's revision layout, chosen in the hecksagon."
        end

        # Refuses every hecksagon bind, world `default_adapter` and world `persisted_by` block that
        # names a removed adapter.
        #
        # @return [self]
        # @raise [WiringError] naming the domain, the removed adapter and its replacement
        def refuse_retired_adapters!
          @declared.hecksagons.each_value { |hecksagon| refuse_retired_binds!(hecksagon) }
          @declared.worlds.each_value { |world| refuse_retired_world!(world) }
          self
        end

        private

        def refuse_retired_binds!(hecksagon)
          retired = hecksagon.binds.find { |bind| RetiredAdapterRule.retired(bind.adapter) }
          refuse_retired!(hecksagon.domain, "its hecksagon binds", retired.adapter) if retired
        end

        def refuse_retired_world!(world)
          named = world_adapter_names(world).find { |name| RetiredAdapterRule.retired(name) }
          refuse_retired!(world.domain, "its world names", named) if named
        end

        # The adapters a world names: its `default_adapter` and each block's adapter.
        def world_adapter_names(world)
          blocks = world.settings.values.select { |value| value.is_a?(Hash) && value.key?(:adapter) }
          [world.default_adapter, *blocks.map { |value| value[:adapter] }].compact.map(&:to_s)
        end

        def refuse_retired!(domain, where, name)
          raise WiringError, RetiredAdapterRule.refusal(domain, where, name)
        end
      end
    end
  end
end
