# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # The edge file that would lead the latest held era to the current shape.
        module Scaffolding
          private

          def scaffold(held, lineage, path)
            eras = held.held_eras(lineage)
            return Readings.no_era(held.bluebook.name, path) if eras.empty?

            scaffold_latest(held, held.named(eras.last))
          end

          # The edge text for the latest era, or why there is nothing to scaffold.
          def scaffold_latest(held, latest)
            shadow = PostgresEra::LineageManager.shadow(latest[:held_text])
            return "#{held.bluebook.name} matches era #{latest[:ordinal]} — nothing to scaffold." if
              Runtime::StorageShape.project(shadow) == held.shape

            edge_text(held, latest, Translation::Scaffold.diff(shadow, held.bluebook))
          end

          def edge_text(held, latest, diffed)
            label = Runtime::StorageShape.mint_hash(held.bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
            edge = Translation::Scaffold::Edge.new(
              domain: held.bluebook.name, from: latest[:label], to: label, ordinal: latest[:ordinal] + 1,
              label: label, aggregates: diffed[:aggregates], retired: diffed[:retired]
            )
            text = Translation::Scaffold.render(edge)
            [*scaffold_notes(edge, text, diffed[:unclaimed]), text].join("\n")
          end

          def scaffold_notes(edge, text, unclaimed)
            unresolved = text.scan(/^\s*unresolved /).size
            notes = ["# Save as translations/#{edge.ordinal}-#{edge.label}.bluebook."]
            notes << "# #{unresolved} unresolved: decide what each became, then boot." if unresolved.positive?
            unclaimed.each do |name|
              notes << "# UNCLAIMED: #{name} existed and now doesn't, and its successor is ambiguous — add " \
                       "`aggregate \"NewName\", was: #{name.inspect}` (with its rules) or `retired #{name.inspect}`."
            end
            notes << "# 0 unresolved: this shape change costs one extra boot and no typing." if notes.size == 1
            notes
          end
        end
      end
    end
  end
end
