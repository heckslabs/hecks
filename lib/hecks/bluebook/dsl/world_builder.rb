require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # A generic keyword-call sink for one bind's own settings block (e.g.
      # `persisted_by "Heki" do dir :default end`) — every method call made
      # on it inside the block is recorded verbatim by name, with no fixed
      # vocabulary of its own; `WorldBuilder#record_binding` reads `#to_h`
      # back out.
      class SettingsCollector
        # Starts with no settings recorded.
        def initialize = @values = {}

        def method_missing(key, *args, &)
          @values[key.to_sym] = args.size == 1 ? args.first : args
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_h = @values
      end

      # The aggregate-qualified mirror (#143) — a `.world` file's own
      # `Pizzas::Order.charged_by("Stripe") do ... end` visually mirrors the
      # same bind line the sibling `.hecksagon` file already writes
      # (`HecksagonBuilder`'s own `BindingProxy`), but `IR::World#for_verb`/
      # `#for_binding` key purely by verb and adapter name — the aggregate
      # qualifier is never read back out, it exists only for that visual
      # mirroring. So unlike `BindingProxy`, nothing here needs to hold onto
      # the resolved constant chain at all: every verb call, qualified or
      # not, has to land in the exact same `@settings` write path
      # (`WorldBuilder#record_binding`).
      class WorldConstProxy
        # Mints the stand-in module a bare domain constant resolves to inside a `.world` block.
        #
        # @param builder [Bluebook::DSL::WorldBuilder] the builder every verb called through the
        #   module's proxies records its settings on
        # @return [Module] an anonymous module whose `const_missing` answers a `WorldConstProxy`,
        #   whatever aggregate name follows `::`
        def self.namespace(builder)
          Module.new do
            define_singleton_method(:const_missing) { |_aggregate| WorldConstProxy.new(builder) }
          end
        end

        # @param builder [Bluebook::DSL::WorldBuilder] the builder verb calls are recorded on
        def initialize(builder) = @builder = builder

        def method_missing(verb, *args, **kwargs, &block) = @builder.record_binding(verb, args, kwargs, block)

        def respond_to_missing?(_name, _include_private = false) = true
      end

      # Parses a `.world` file's top-level DSL block into a `World` — a
      # domain's own `realm`/`latest` version markers plus its adapter bind
      # settings, one entry per `verb("Adapter") do ... end` call (whether
      # written bare or aggregate-qualified through `WorldConstProxy`'s
      # visual mirror of a sibling `.hecksagon` file's own bind).
      class WorldBuilder
        GRAMMAR_CONTEXT = "World".freeze

        include WordGate

        # @param domain [String] name of the domain whose world this is
        def initialize(domain)
          @domain   = domain
          @settings = {}
        end

        # Names the realm this world belongs to, such as `"Examples"` or `"QA"`.
        #
        # `realm_impl`/`latest_impl` answer the `realm`/`latest` words
        # through the table's `calls:` column — item #13's full
        # metaprogrammed dispatch (slice 5). Neither bootstrap-reachable
        # (checked directly). Reached through `WordGate`'s
        # `word_gate_dispatch`, called explicitly below since
        # `WorldBuilder`'s own class-level `method_missing` (the
        # open-verb catch-all beneath this) always wins over the
        # module's — see `word_gate.rb`'s own header for the full
        # mechanism.
        #
        # @param value [String, Symbol] the realm's name; blankness is judged by the world
        #   language at `build`, not here
        # @return [String] the realm as stored
        def realm_impl(value)
          @realm = required(value, "realm")
        end

        # Names the bluebook version this world treats as latest, which `ProjectRegister` compares
        # with the bluebook's own declared `version`.
        #
        # @param value [String, Symbol, Numeric] the version marker; blankness is judged by the
        #   world language at `build`, not here
        # @return [String] the version as stored
        def latest_impl(value)
          @latest = required(value, "latest version")
        end

        def method_missing(verb, *args, **kwargs, &block)
          result = word_gate_dispatch(verb, args, kwargs, block)
          return result unless result.equal?(WordGate::NOT_ADMITTED)

          record_binding(verb, args, kwargs, block)
        end

        def respond_to_missing?(_name, _include_private = false) = true

        # Records one bind's settings under both its verb and its `verb:adapter` key.
        #
        # A method of its own, apart from `method_missing` (#143), so
        # `WorldConstProxy`'s own aggregate-qualified verb calls
        # (`Pizzas::Order.charged_by(...)`) write into the exact same
        # place the bare top-level spelling (`charged_by(...)`) already
        # does — one write path, two spellings.
        #
        # @param verb [Symbol, String] the bind verb, such as `:persisted_by`
        # @param args [Array<Object>] the call's positional arguments; the first names the adapter
        # @param kwargs [Hash{Symbol => Object}] settings given inline as keyword arguments
        # @param block [Proc, nil] a settings block, evaluated against a `SettingsCollector`
        # @return [Hash{Symbol => Object}] the settings just recorded: `:adapter` (a String),
        #   then the keyword arguments, then the block's settings, later ones winning
        def record_binding(verb, args, kwargs, block)
          collector = SettingsCollector.new
          collector.instance_eval(&block) if block
          value = { adapter: args.first.to_s }.merge(kwargs).merge(collector.to_h)
          @settings[verb.to_s] = value
          @settings["#{verb}:#{args.first.to_s.downcase}"] = value
        end

        # Assembles the realm, version marker and bind settings, judged by the world language.
        #
        # @return [Bluebook::World] the world, returned once the language accepts it
        # @raise [Bluebook::DSL::Malformed] if the world language refuses the declaration, such
        #   as a blank `realm`
        def build
          MetaValidator.call_world(
            World.new(domain: @domain, realm: @realm, latest: @latest, settings: @settings)
          )
        end

        # Evaluates a `Hecks.world` block against a fresh builder and returns the world it declared.
        #
        # `ConstShim`'s resolver, the same bridge `HecksagonBuilder`/
        # `BluebookBuilder` already wrap their own `instance_eval` in
        # (#143) — without it, `Pizzas::Order.charged_by(...)` raises
        # `NameError: uninitialized constant Pizzas` for every `.world`
        # file using the aggregate-qualified mirror form, since a bare
        # `Pizzas` has no real constant to resolve to.
        #
        # @param domain [String] name of the domain whose world this is
        # @yield the world body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::World] the judged world
        # @raise [Bluebook::DSL::Malformed] if the world language refuses the declaration
        def self.build(domain, &block)
          builder  = new(domain)
          resolver = ->(_domain) { WorldConstProxy.namespace(builder) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end

        private

        def required(value, _label)
          # moved to the language: Realm / Latest invariants, in world.bluebook
          value.to_s
        end
      end
    end
  end
end
