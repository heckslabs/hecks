module Hecks
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

        # The generic `verb` entry (`persisted_by("Heki") do dir :default
        # end`) only answers for the adapter it actually names — falling
        # back to it unconditionally applies one adapter's settings to an
        # unrelated one. Real, corpus-caught bug: a hecksagon binding two
        # aggregates to two different adapters under the SAME verb (one to
        # Heki, one to Memory) sent Memory's lookup down Heki's generic
        # entry, then failed `check_settings` with "Memory does not
        # declare :dir" — the generic entry's own `settings[:adapter]`
        # names Heki, not Memory, so the fallback was never actually for
        # this bind. `{}` is exactly right when nothing was configured for
        # THIS adapter — Memory, which takes no values at all.
        def for_binding(verb, adapter)
          qualified = @settings["#{verb}:#{adapter.to_s.downcase}"]
          return qualified if qualified

          generic = for_verb(verb)
          generic[:adapter].to_s.downcase == adapter.to_s.downcase ? generic : {}
        end
      end
    end
  end
end
