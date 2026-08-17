require_relative "word_gate"
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
        GRAMMAR_CONTEXT = "World"

        include WordGate

        def initialize(domain)
          @domain   = domain
          @settings = {}
        end

        def realm(value)
          @realm = required(value, "realm")
        end

        def latest(value)
          @latest = required(value, "latest version")
        end

        def method_missing(verb, *args, **kwargs, &block)
          collector = SettingsCollector.new
          collector.instance_eval(&block) if block
          value = { adapter: args.first.to_s }.merge(kwargs).merge(collector.to_h)
          @settings[verb.to_s] = value
          @settings["#{verb}:#{args.first.to_s.downcase}"] = value
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def build
          MetaValidator.call_world(
            World.new(domain: @domain, realm: @realm, latest: @latest, settings: @settings)
          )
        end

        def self.build(domain, &block)
          builder = new(domain)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def required(value, label)
          # moved to the language: Realm / Latest invariants, in world.bluebook
          value.to_s
        end
      end
    end
  end
end
