module Hecks
  module Bluebook
    module Behaviour
      # **What a hecksagon does** — the lookups over its declared binds.
      module Hecksagon
        # Aggregate-specific bind wins when one was declared; otherwise
        # falls back to a domain-level default (`b.aggregate.nil?` — see
        # `HecksagonBuilder#method_missing`). Checked directly rather than
        # via `aggregate_name`/`Naming.demodulise`, which would need its own
        # nil-handling for the default row.
        #
        # @param aggregate_name [String, Symbol] the aggregate's name to prefer a
        #   specific bind for
        # @param verb [String, Symbol] the bind verb, such as `"persisted_by"`
        # @return [Bluebook::Bind, nil] the aggregate-specific bind for `verb`, the
        #   domain-level default bind for `verb` if none is aggregate-specific, or `nil`
        #   if neither is declared
        def bind_for(aggregate_name, verb)
          @binds.find { |b| b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s } ||
            @binds.find { |b| b.aggregate.nil? && b.verb.to_s == verb.to_s }
        end

        # Finds every bind for `verb`, preferring aggregate-specific binds over the
        # domain-level default the same way `bind_for` does, but returning all matches
        # rather than the first.
        #
        # @param aggregate_name [String, Symbol] the aggregate's name to prefer
        #   specific binds for
        # @param verb [String, Symbol] the bind verb, such as `"projected_by"`
        # @return [Array<Bluebook::Bind>] every aggregate-specific bind for `verb`, or,
        #   if there are none, every domain-level default bind for `verb`
        def binds_for(aggregate_name, verb)
          specific = @binds.select { |b| b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s }
          return specific if specific.any?

          @binds.select { |b| b.aggregate.nil? && b.verb.to_s == verb.to_s }
        end
      end

      # **What a world does** — settings lookup, with the adapter-specific
      # entry falling back to the verb's own.
      module World
        # Looks up the settings declared for one bind verb.
        #
        # @param verb [String, Symbol] the bind verb, such as `"dispatched_by"`
        # @return [Hash] the settings declared for `verb`, or `{}` if none are declared
        def for_verb(verb) = @settings.fetch(verb.to_s, {})

        # The generic `verb` entry (`persisted_by("Heki") do dir :default
        # end`) only answers for the adapter it actually names — falling
        # back to it unconditionally applies one adapter's settings to an
        # unrelated one. Real, corpus-caught bug: a hecksagon binding two
        # aggregates to two different adapters under the same verb (one to
        # Heki, one to Memory) sent Memory's lookup down Heki's generic
        # entry, then failed `check_settings` with "Memory does not
        # declare :dir" — the generic entry's own `settings[:adapter]`
        # names Heki, not Memory, so the fallback was never actually for
        # this bind. `{}` is exactly right when nothing was configured for
        # this adapter — Memory, which takes no values at all.
        #
        # @param verb [String, Symbol] the bind verb, such as `"persisted_by"`
        # @param adapter [String, Symbol] the bound adapter's name, such as `"Postgres"`
        # @return [Hash] the settings qualified for this exact verb/adapter pair if
        #   declared, else the verb's generic entry if it names this same adapter,
        #   else `{}`
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
