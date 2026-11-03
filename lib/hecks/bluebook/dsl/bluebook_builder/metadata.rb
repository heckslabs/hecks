module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        # The words that describe the whole bluebook rather than one construct in it: its earlier
        # name, the Ruby module its constants install under, and its classification. Each refuses
        # to sit inside a `domain_module` block, since a module names a task, not the bluebook.
        module Metadata
          # Records the bluebook's earlier name, so the storage layer recognizes its history
          # under it instead of minting a new lineage — a bluebook's identity can change.
          #
          # @param value [String, Symbol] the bluebook's earlier name
          # @return [String] `value`, stringified, as stored
          def formerly_known_as(value)
            bluebook_wide!(:formerly_known_as)
            @formerly_known_as = value.to_s
          end

          # Names the Ruby module the bluebook's constants install under instead of its own name,
          # such as `namespace "Hecks::Domain"` for a bluebook that would otherwise collide.
          #
          # @param value [String] a constant path, such as `"Hecks::Domain"`
          # @return [String] `value`, stringified, as stored
          def namespace(value)
            bluebook_wide!(:namespace)
            @namespace = value.to_s
          end

          # Classifies this bluebook as the core subdomain: where the domain's advantage lies, which
          # no generic context may depend on and which translates rather than conforms (ADR 0172).
          #
          # @return [Symbol] `:core`
          def core       = classify(:core)

          # Classifies this bluebook as a supporting subdomain: specific to this business, but not
          # where its advantage lies.
          #
          # @return [Symbol] `:supporting`
          def supporting = classify(:supporting)

          # Classifies this bluebook as a generic subdomain: a solved problem that could be bought
          # or attached, so it may not depend on the core (ADR 0172).
          #
          # @return [Symbol] `:generic`
          def generic    = classify(:generic)

          private

          # Sets how this bluebook is classified, which describes the whole of it.
          def classify(kind)
            bluebook_wide!(kind)
            @classification = kind
          end
        end
      end
    end
  end
end
