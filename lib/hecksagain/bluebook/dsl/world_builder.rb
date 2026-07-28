module Hecksagain
  module Bluebook
    module DSL
      class SettingsCollector
        def initialize = @values = {}

        def method_missing(key, *args, &_block)
          @values[key.to_sym] = args.size == 1 ? args.first : args
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_h = @values
      end

      class WorldBuilder
        def initialize(domain)
          @domain   = domain
          @settings = {}
        end

        def method_missing(verb, *args, &block)
          collector = SettingsCollector.new
          collector.instance_eval(&block) if block
          @settings[verb.to_s] = { adapter: args.first.to_s }.merge(collector.to_h)
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def build = IR::World.new(domain: @domain, settings: @settings)

        def self.build(domain, &block)
          builder = new(domain)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
