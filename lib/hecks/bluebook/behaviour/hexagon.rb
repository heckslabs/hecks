module Hecks
  module Bluebook
    module Behaviour
      # Lookups over a hecksagon's declared binds.
      module Hecksagon
        # Finds the bind for an aggregate and verb, falling back to the domain-level default.
        #
        # The default row is matched with `b.aggregate.nil?` rather than via
        # `aggregate_name`, which would need its own nil handling.
        #
        # @param aggregate_name [String, Symbol]
        # @param verb [String, Symbol]
        # @return [Bluebook::Bind, nil]
        def bind_for(aggregate_name, verb)
          @binds.find { |b| b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s } ||
            @binds.find { |b| b.aggregate.nil? && b.verb.to_s == verb.to_s }
        end

        # Every bind for `verb`; aggregate-specific ones win as a group over the default.
        #
        # @param aggregate_name [String, Symbol]
        # @param verb [String, Symbol]
        # @return [Array<Bluebook::Bind>]
        def binds_for(aggregate_name, verb)
          specific = @binds.select { |b| b.aggregate_name == aggregate_name.to_s && b.verb.to_s == verb.to_s }
          return specific if specific.any?

          @binds.select { |b| b.aggregate.nil? && b.verb.to_s == verb.to_s }
        end
      end

      # Settings lookup for a world, with adapter-specific entries falling back to the verb's own.
      module World
        # The settings declared for a port verb.
        #
        # @param verb [String, Symbol] such as `"persistence"`
        # @return [Hash{Symbol => Object}] empty when none are declared
        def for_verb(verb) = @settings.fetch(verb.to_s, {})

        # The generic verb entry only answers for the adapter it names. Falling back to it
        # unconditionally would apply one adapter's settings (Heki's `dir`) to another
        # (Memory), which then fails `check_settings`.
        #
        # @param verb [String, Symbol]
        # @param adapter [String, Symbol] such as `"Heki"`
        # @return [Hash{Symbol => Object}] the adapter-qualified settings, else the generic
        #   ones when they name this adapter, else `{}`
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
