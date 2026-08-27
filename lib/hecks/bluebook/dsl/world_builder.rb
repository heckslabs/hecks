require_relative "word_gate"
module Hecks
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

      # THE AGGREGATE-QUALIFIED MIRROR (#143) — a `.world` file's own
      # `Pizzas::Order.charged_by("Stripe") do ... end` visually mirrors the
      # SAME bind line the sibling `.hecksagon` file already writes
      # (`HecksagonBuilder`'s own `BindingProxy`), but `IR::World#for_verb`/
      # `#for_binding` key purely by verb and adapter name — the aggregate
      # qualifier is never read back out, it exists only for that visual
      # mirroring. So unlike `BindingProxy`, nothing here needs to hold onto
      # the resolved constant chain at all: every verb call, qualified or
      # not, has to land in the exact same `@settings` write path
      # (`WorldBuilder#record_binding`).
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

      class WorldBuilder
        GRAMMAR_CONTEXT = "World"

        include WordGate

        def initialize(domain)
          @domain   = domain
          @settings = {}
        end

        # RENAMED FROM `realm`/`latest` — item #13's full metaprogrammed
        # dispatch (slice 5). Neither bootstrap-reachable (checked
        # directly). Reached through `WordGate#method_missing`'s new
        # `word_gate_dispatch`, called explicitly below since
        # `WorldBuilder`'s own class-level `method_missing` (the
        # open-verb catch-all beneath this) always wins over the
        # module's — see `word_gate.rb`'s own header for the full
        # mechanism.
        def realm_impl(value)
          @realm = required(value, "realm")
        end

        def latest_impl(value)
          @latest = required(value, "latest version")
        end

        def method_missing(verb, *args, **kwargs, &block)
          result = word_gate_dispatch(verb, args, kwargs, block)
          return result unless result.equal?(WordGate::NOT_ADMITTED)

          record_binding(verb, args, kwargs, block)
        end

        def respond_to_missing?(_name, _include_private = false) = true

        # EXTRACTED from the old `method_missing` body (#143) so
        # `WorldConstProxy`'s own aggregate-qualified verb calls
        # (`Pizzas::Order.charged_by(...)`) write into the exact same
        # place the bare top-level spelling (`charged_by(...)`) already
        # does — one write path, two spellings.
        def record_binding(verb, args, kwargs, block)
          collector = SettingsCollector.new
          collector.instance_eval(&block) if block
          value = { adapter: args.first.to_s }.merge(kwargs).merge(collector.to_h)
          @settings[verb.to_s] = value
          @settings["#{verb}:#{args.first.to_s.downcase}"] = value
        end

        def build
          MetaValidator.call_world(
            World.new(domain: @domain, realm: @realm, latest: @latest, settings: @settings)
          )
        end

        # `ConstShim`'s resolver, the same bridge `HecksagonBuilder`/
        # `BluebookBuilder` already wrap their own `instance_eval` in
        # (#143) — without it, `Pizzas::Order.charged_by(...)` raised
        # `NameError: uninitialized constant Pizzas` for every `.world`
        # file using the aggregate-qualified mirror form, since a bare
        # `Pizzas` has no real constant to resolve to.
        def self.build(domain, &block)
          builder  = new(domain)
          resolver = ->(_domain) { WorldConstProxy.namespace(builder) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
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
