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

      Bind = Struct.new(:aggregate, :verb, :adapter, keyword_init: true) do
        def aggregate_name = Naming.demodulise(aggregate)
      end

      class Hecksagon
        attr_reader :domain, :binds

        def initialize(domain:, binds: [])
          @domain = domain.to_s
          @binds  = binds
        end

        def bind_for(aggregate_name, verb)
          @binds.find do |b|
            b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s
          end
        end

        def to_h = { domain: @domain, binds: @binds.map(&:to_h) }
      end

      class World
        attr_reader :domain, :settings

        def initialize(domain:, settings: {})
          @domain   = domain.to_s
          @settings = settings
        end

        def for_verb(verb) = @settings.fetch(verb.to_s, {})

        def to_h = { domain: @domain, settings: @settings }
      end
    end
  end
end
