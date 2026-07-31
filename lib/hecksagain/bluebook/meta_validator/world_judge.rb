module Hecksagain
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

        def args(pairs) = pairs.reject { |_, value| value.nil? }

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
               Runtime::TypeMismatch, Runtime::NotFound => e
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        def send_to(verb, label, **payload)
          offer(label) { @runtime.dispatch(verb, **args(payload)) }
        end

        def judge!
          domain = @world.domain
          send_to("Deployment::World.Declare", domain, domain: v(domain),
                  realm: v(@world.realm), latest: v(@world.latest))

          Hash(@world.settings).each do |verb, values|
            # the DSL records each binding twice — once by verb, once by
            # "verb:adapter" — so only the plain verb is offered
            next if verb.to_s.include?(":")

            judge_wiring(domain, verb, values)
          end
        end

        def judge_wiring(domain, verb, values)
          id = "#{domain}.#{verb}"
          # `world_id` is the WORLD's id and goes bare, the way every reference
          # does now ; `world` beside it is an ordinary text attribute that happens
          # to hold the same string, and stays a value object. The two look alike
          # and are not — which is exactly why the judge asks the type rather than
          # the name.
          send_to("Deployment::Wiring.Declare", id, id: id, world_id: domain,
                  world: v(domain), verb: v(verb), adapter: v(Hash(values)[:adapter]))

          Hash(values).each do |key, value|
            next if key.to_sym == :adapter

            send_to("Deployment::Wiring.Set", id, id: id, key: v(key), value: v(value))
          end
        end
      end
    end
  end
end
