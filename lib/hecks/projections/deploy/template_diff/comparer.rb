require_relative "normalizer"
require_relative "value_diff"

module Hecks
  module Projections
    module Deploy
      module TemplateDiff
        # Compares two loaded CloudFormation templates, matching entries by an
        # identity field such as `Name` or `Id` rather than by position.
        module Comparer
          module_function

          Change = Struct.new(:path, :kind, :before, :after, :cosmetic, keyword_init: true)
          Entity = Struct.new(:name, :type, :changes, :replaced, keyword_init: true)
          SectionDiff = Struct.new(:added, :removed, :changed, keyword_init: true) do
            def empty? = added.empty? && removed.empty? && changed.empty?
          end

          ENTITY_SECTIONS = %w[Parameters Resources Outputs Conditions Mappings].freeze

          # Diffs each entity section by name, with other top-level keys grouped under "Template".
          #
          # @param before [Hash] the template before, as loaded
          # @param after [Hash] the template after, as loaded
          # @return [Hash{String => SectionDiff, Array<Change>}] one diff per section present
          def compare(before, after)
            before = Normalizer.normalize(before)
            after = Normalizer.normalize(after)
            diff = ENTITY_SECTIONS.each_with_object({}) do |section, sections|
              next unless before.key?(section) || after.key?(section)

              sections[section] = section_diff(section, before[section] || {}, after[section] || {})
            end
            diff["Template"] = template_changes(before, after)
            diff
          end

          def section_diff(section, before, after)
            SectionDiff.new(
              added:   listed(section, after, before),
              removed: listed(section, before, after),
              changed: (before.keys & after.keys).sort.filter_map { |name| entity_diff(section, name, before[name], after[name]) }
            )
          end
          private_class_method :section_diff

          # The `[name, type]` of each entity in `side` that `other` lacks.
          def listed(section, side, other)
            (side.keys - other.keys).sort.map { |name| [name, type_of(section, side[name])] }
          end
          private_class_method :listed

          def type_of(section, entity)
            entity.is_a?(Hash) && %w[Resources Parameters].include?(section) ? entity["Type"] : nil
          end
          private_class_method :type_of

          def entity_diff(section, name, before, after)
            return nil if before == after

            changes = []
            ValueDiff.diff_values("", before, after, changes)
            return nil if changes.empty?

            replaced = section == "Resources" && before.is_a?(Hash) && after.is_a?(Hash) && before["Type"] != after["Type"]
            Entity.new(name: name, type: type_of(section, after), changes: changes, replaced: replaced)
          end
          private_class_method :entity_diff

          def template_changes(before, after)
            changes = []
            others = (before.keys | after.keys) - ENTITY_SECTIONS
            others.sort.each do |key|
              ValueDiff.diff_values(key, before[key], after[key], changes) unless before[key] == after[key]
            end
            changes
          end
          private_class_method :template_changes
        end
      end
    end
  end
end
