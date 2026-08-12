module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A HECKSAGON DOES — the lookups over its declared binds.
      module Hecksagon
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
      end

      # WHAT A WORLD DOES — settings lookup, with the adapter-specific
      # entry falling back to the verb's own.
      module World
        def for_verb(verb) = @settings.fetch(verb.to_s, {})

        def for_binding(verb, adapter)
          @settings.fetch("#{verb}:#{adapter.to_s.downcase}", for_verb(verb))
        end
      end
    end
  end
end
