module Hecks
  module Bluebook
    module MetaValidator
      # Judges a built .world against the language that describes worlds,
      # normalizing its settings into one Wiring per verb, one Setting per value.
      class WorldJudge
        attr_reader :refusals

        def initialize(world)
          @world    = world
          @refusals = []
          @runtime  = MetaValidator.fresh_runtime
          judge!
        end

        private

        def v(text) = text.nil? ? nil : { value: text.to_s }

        def args(pairs) = pairs.compact

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
               Runtime::TypeMismatch, Runtime::NotFound => e
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        def send_to(verb, label, to: nil, **payload)
          offer(label) { @runtime.dispatch(verb, to: to, with: args(payload)) }
        end

        def judge!
          domain = @world.domain
          declare_world(domain)

          Hash(@world.settings).each do |verb, values|
            # the DSL records each binding twice — once by verb, once by
            # "verb:adapter" — so only the plain verb is offered
            next if verb.to_s.include?(":")

            judge_wiring(domain, verb, values)
          end
        end

        def declare_world(domain)
          send_to("World::World.Declare", domain, domain: v(domain),
                  realm: v(@world.realm), latest: v(@world.latest),
                  default_database: v(@world.default_database),
                  default_adapter: v(@world.default_adapter))
        end

        def judge_wiring(domain, verb, values)
          # Must match Wiring's own `identified_by do world; verb.value end`
          # derivation exactly, or a later `Wiring.Set` could never find it.
          id = Naming.identity([domain, verb])
          # `world_ref` is the type-checked reference; the plain `world`
          # attribute alongside it just happens to hold the same string.
          send_to("World::Wiring.Declare", id, world_ref: v(domain),
                  world: v(domain), verb: v(verb), adapter: v(Hash(values)[:adapter]))

          Hash(values).each do |key, value|
            next if key.to_sym == :adapter

            send_to("World::Wiring.Set", id, to: id, key: v(key), value: v(value))
          end
        end
      end
    end
  end
end
