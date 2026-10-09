module Hecks
  module Projector
    module Exporter
      # The values a capability's optional contract entries resolve to in the exported fact: the
      # states of a lifecycle `:mark` (ADR 0097) and the whole seconds of a `:duration` (ADR 0098).
      module CapabilityValues
        private

        # `{ key => states }` for each optional `:mark` entry `provider` declares under
        # `capability`.
        def all_marked_states(provider, capability)
          mark_keys = declared_keys(capability, :mark)
          mark_keys.reduce({}) { |marks, key| marks.merge(marked_states(provider, capability, key)) }
        end

        # `{ key => seconds }` for each optional `:duration` entry `provider` declares under
        # `capability`: the whole-seconds default of the attribute it names.
        def all_durations(provider, capability)
          declared_keys(capability, :duration).each_with_object({}) do |key, durations|
            verb = provider.provision(capability)&.fetch(key, nil)
            durations[key] = Bluebook::Capabilities.duration_of(provider, verb) if verb
          end
        end

        # `{ key => states }` for an optional `:mark` entry `provider` declares under `capability`:
        # the states of the named aggregate's lifecycle mark. `{}` when the entry is not declared.
        def marked_states(provider, capability, key)
          verb = provider.provision(capability)&.fetch(key, nil)
          return {} unless verb

          aggregate_name, mark = verb.split(".", 2)
          { key => provider.aggregate(aggregate_name).lifecycle.marked(mark) }
        end

        # The contract keys of `capability` whose kind is `kind`.
        def declared_keys(capability, kind)
          Bluebook::Capabilities::CONTRACTS.fetch(capability).select { |_, entry| entry == kind }.keys
        end
      end
    end
  end
end
