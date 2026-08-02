module Hecksagain
  module Bluebook
    module IR
      Port = Struct.new(:name, :verb, :signal, keyword_init: true) do
        def reply?  = signal == :reply
        def effect? = signal == :effect
      end

      Adapter = Struct.new(:name, :port, :fields, :secrets, keyword_init: true) do
        def declares?(field) = all_fields.include?(field.to_sym)

        def all_fields = (fields || []) + (secrets || [])
      end

      Bind = Struct.new(:aggregate, :verb, :adapter, :role, keyword_init: true) do
        def aggregate_name = Naming.demodulise(aggregate)
      end

      class Hecksagon
        attr_reader :domain, :binds, :subscriptions

        def initialize(domain:, binds: [], subscriptions: [])
          @domain        = domain.to_s
          @binds         = binds
          @subscriptions = subscriptions
        end

        def bind_for(aggregate_name, verb)
          @binds.find do |b|
            b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s
          end
        end

        def binds_for(aggregate_name, verb)
          @binds.select do |b|
            b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s
          end
        end

        def to_h = { domain: @domain, binds: @binds.map(&:to_h), subscriptions: @subscriptions.map(&:to_s) }
      end

      class World
        attr_reader :domain, :realm, :latest, :settings

        def initialize(domain:, realm: nil, latest: nil, settings: {})
          @domain   = domain.to_s
          @realm    = realm&.to_s
          @latest   = latest&.to_s
          @settings = settings
        end

        def for_verb(verb) = @settings.fetch(verb.to_s, {})

        def for_binding(verb, adapter)
          @settings.fetch("#{verb}:#{adapter.to_s.downcase}", for_verb(verb))
        end

        def to_h = { domain: @domain, realm: @realm, latest: @latest, settings: @settings }
      end
    end
  end
end
