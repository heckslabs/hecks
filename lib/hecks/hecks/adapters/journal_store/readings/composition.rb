# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # The dry run of `write_translation`: the edge that would be written, and the files it would
        # delete, answered as text and written nowhere.
        module Composition
          # The composed edge `write_translation` would write, under comments that say which files
          # it would remove.
          #
          # @param domain [Hash, String] the domain directory
          # @return [Hash] `text:` the edge file's text, or the sentence that says nothing is to be written
          # @raise [Runtime::NotFound] if the domain holds no eras, cannot be loaded, or its chain
          #   cannot be composed
          def compose_translation(domain:)
            answering do
              held = HeldDomain.open(plain(domain))
              refuse_incapable!(held)
              held.reading { |lineage| composition_text(held, lineage) }
            end
          end

          private

          def composition_text(held, lineage)
            plan = translation_plan(held, lineage)
            return plan.message if plan.message

            notes = ["# Would write #{plan.path}."]
            notes += plan.removals.map { |path| "# Would delete #{path}." }
            [*notes, plan.text.chomp].join("\n")
          end
        end
      end
    end
  end
end
