# The boundary IR — Family, Adapter, Bind, Hecksagon, World.
#
# The shape carried over from Hecks, and the reason the adapter pattern works
# without the domain knowing anything:
#
#   Family   names a HOW-VERB (persisted_by) and the config FIELDS its adapters
#            need — names only, never values.
#   Adapter  DECLARES the family it implements (the inverted arrow). The family
#            never names its adapters, so a new backend is additive.
#   Bind     hangs `aggregate.how_verb("Adapter")` — the wiring.
#   World    hangs VALUES off the same selector, per deployment.
#
# A bind resolves only if the named adapter's family carries the bind's verb.
# That check is the typed attach checkpoint — it fails loudly at boot, not at
# first fire.
module Hecksagain
  module Language
    module IR
      # verb   — "persisted_by"
      # signal — :reply (returns a value) or :effect (emits, verdict re-enters)
      # fields — config field NAMES the adapters need ; values live in .world
      Family = Struct.new(:name, :verb, :signal, :fields, keyword_init: true) do
        def reply?  = signal == :reply
        def effect? = signal == :effect
      end

      # name   — "Sqlite"
      # family — the family name it implements (the inverted arrow)
      Adapter = Struct.new(:name, :family, keyword_init: true)

      # aggregate — "Pizzas::Pizza"
      # verb      — "persisted_by"
      # adapter   — "Sqlite"
      Bind = Struct.new(:aggregate, :verb, :adapter, keyword_init: true) do
        # The bare aggregate name, without its domain prefix.
        def aggregate_name = aggregate.to_s.split("::").last
      end

      class Hecksagon
        attr_reader :domain, :binds

        def initialize(domain:, binds: [])
          @domain = domain.to_s
          @binds  = binds
        end

        # The bind wiring a given aggregate through a given how-verb.
        def bind_for(aggregate_name, verb)
          @binds.find do |b|
            b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s
          end
        end

        def to_h = { domain: @domain, binds: @binds.map(&:to_h) }
      end

      # Per-deployment values, keyed by how-verb (and optionally by aggregate).
      class World
        attr_reader :domain, :settings

        def initialize(domain:, settings: {})
          @domain   = domain.to_s
          @settings = settings
        end

        # Values declared for a verb — e.g. persisted_by("Sqlite") { database ... }
        def for_verb(verb) = @settings.fetch(verb.to_s, {})

        def to_h = { domain: @domain, settings: @settings }
      end
    end
  end
end
