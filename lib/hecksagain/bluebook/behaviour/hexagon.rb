module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A HECKSAGON DOES — the lookups over its declared binds.
      module Hecksagon
        # Aggregate-specific bind wins when one was declared; otherwise
        # falls back to a domain-level default (`b.aggregate.nil?` — see
        # `HecksagonBuilder#method_missing`). Checked directly rather than
        # via `aggregate_name`/`Naming.demodulise`, which would need its own
        # nil-handling for the default row.
        def bind_for(aggregate_name, verb)
          @binds.find { |b| b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s } ||
            @binds.find { |b| b.aggregate.nil? && b.verb.to_s == verb.to_s }
        end

        def binds_for(aggregate_name, verb)
          specific = @binds.select { |b| b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s }
          return specific if specific.any?

          @binds.select { |b| b.aggregate.nil? && b.verb.to_s == verb.to_s }
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
