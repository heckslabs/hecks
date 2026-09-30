require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Records every keyword call made inside a bind's settings block, by name, with
      # no fixed vocabulary of its own.
      class SettingsCollector
        def initialize = @values = {}

        # A call with a block records its own settings as a nested Hash; a bare call
        # keeps a single argument as is, several as an array.
        def method_missing(key, *args, &block)
          @values[key.to_sym] =
            if block
              nested = SettingsCollector.new
              nested.instance_eval(&block)
              nested.to_h
            else
              args.size == 1 ? args.first : args
            end
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_h = @values
      end

      # Stands in for a bare aggregate constant inside a `.world` block, so a bind line
      # can visually mirror its sibling `.hecksagon` spelling; the qualifier is never read back out.
      class WorldConstProxy
        def self.namespace(builder)
          Module.new do
            define_singleton_method(:const_missing) { |_aggregate| WorldConstProxy.new(builder) }
          end
        end

        def initialize(builder) = @builder = builder

        def method_missing(verb, *args, **kwargs, &block) = @builder.record_binding(verb, args, kwargs, block)

        def respond_to_missing?(_name, _include_private = false) = true
      end

      # Parses a `.world` file's top-level DSL block into a `World` — a domain's own
      # `realm`/`latest` markers plus its adapter bind settings.
      class WorldBuilder
        GRAMMAR_CONTEXT = "World".freeze

        include WordGate

        def initialize(domain)
          @domain   = domain
          @settings = {}
        end

        # Reached through `WordGate`'s `word_gate_dispatch`, called explicitly since this
        # class's own `method_missing` would otherwise always win over the module's.
        def realm_impl(value)
          @realm = required(value, "realm")
        end

        # `ProjectRegister` compares this against the bluebook's own declared `version`.
        def latest_impl(value)
          @latest = required(value, "latest version")
        end

        # A chapter's own `persisted_by("Adapter") { database ... }` still wins for that adapter.
        def default_database_impl(value)
          @default_database = required(value, "default database")
        end

        # Sits between an explicit bind and the framework's in-memory fallback; whether the
        # adapter really is a persistence adapter is judged at boot, where adapters are known.
        def default_adapter_impl(value)
          @default_adapter = required(value, "default adapter")
        end

        def method_missing(verb, *args, **kwargs, &block)
          result = word_gate_dispatch(verb, args, kwargs, block)
          return result unless result.equal?(WordGate::NOT_ADMITTED)

          record_binding(verb, args, kwargs, block)
        end

        def respond_to_missing?(_name, _include_private = false) = true

        # A method of its own, apart from `method_missing`, so `WorldConstProxy`'s
        # aggregate-qualified verb calls write into the same place the bare spelling does.
        def record_binding(verb, args, kwargs, block)
          collector = SettingsCollector.new
          collector.instance_eval(&block) if block
          value = { adapter: args.first.to_s }.merge(kwargs).merge(collector.to_h)
          @settings[verb.to_s] = value
          @settings["#{verb}:#{args.first.to_s.downcase}"] = value
        end

        def build
          MetaValidator.call_world(
            World.new(domain: @domain, realm: @realm, latest: @latest, settings: @settings,
                      default_database: @default_database, default_adapter: @default_adapter)
          )
        end

        class << self
          # The builder whose block is being evaluated, so an aggregate door a facade already
          # installed (a repeat boot in one process) can record a qualified bind into it.
          #
          # @return [Bluebook::DSL::WorldBuilder, nil] nil outside a `.world` block
          attr_reader :current
        end

        # Wraps `instance_eval` in `ConstShim`'s resolver: without it, an aggregate-qualified
        # verb call raises `NameError`, since the bare constant has nothing to resolve to.
        # A bare name resolves to a namespace whose `::` reaches the proxy; a qualified path
        # (`Pizzas::Order`, handed over by an installed facade chapter's `const_missing`)
        # is already the aggregate, so it resolves to the proxy itself.
        #
        # @param domain [String] the domain the world belongs to
        # @yield the world's DSL block
        # @return [Bluebook::World] the judged world
        def self.build(domain, &block)
          builder  = new(domain)
          resolver = lambda do |name|
            name.to_s.include?("::") ? WorldConstProxy.new(builder) : WorldConstProxy.namespace(builder)
          end
          evaluate(builder, resolver, &block) if block
          builder.build
        end

        # @api private
        def self.evaluate(builder, resolver, &block)
          previous = @current
          @current = builder
          ConstShim.with(resolver) { builder.instance_eval(&block) }
        ensure
          @current = previous
        end
        private_class_method :evaluate

        private

        def required(value, _label)
          # Validation lives in the world language (world.bluebook), not here.
          value.to_s
        end
      end
    end
  end
end
