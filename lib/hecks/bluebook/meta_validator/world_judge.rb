module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built .world to the language that describes worlds.
      #
      # A world is a SIBLING of a bluebook — the same domain runs in many of
      # them — so it is judged through its own door, against its own language
      # file, and its settings normalise the same way a mutation's fields do:
      # an open map becomes one Wiring per verb and one Setting row per value.
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
          send_to("World::World.Declare", domain, domain: v(domain),
                  realm: v(@world.realm), latest: v(@world.latest))

          Hash(@world.settings).each do |verb, values|
            # the DSL records each binding twice — once by verb, once by
            # "verb:adapter" — so only the plain verb is offered
            next if verb.to_s.include?(":")

            judge_wiring(domain, verb, values)
          end
        end

        def judge_wiring(domain, verb, values)
          # THE SAME JOIN THE LANGUAGE ITSELF DERIVES. Wiring is
          # `identified_by do world; verb.value end` — `Wiring.Declare`
          # (a creating command) ignores this `id:` entirely and computes its OWN
          # from `world`/`verb`, so a locally minted "#{domain}.#{verb}" named a
          # record `Wiring.Set` could never find : the id passed here has to be
          # the SAME derivation, not a second guess at what it must be.
          id = Naming.identity([domain, verb])
          # `world_ref` is the WORLD's id and goes bare, the way every reference
          # does now ; the language gives it that explicit `as:` because `world`
          # beside it is an ordinary text attribute that happens to hold the same
          # string, and stays a value object. The two look alike and are not —
          # which is exactly why the judge asks the type rather than the name.
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
