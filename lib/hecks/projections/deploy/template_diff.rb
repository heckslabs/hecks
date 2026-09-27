require "json"
require_relative "template_diff/loader"
require_relative "template_diff/comparer"

module Hecks
  module Projections
    module Deploy
      # An offline diff of two CloudFormation templates: what would change if one replaced
      # the other, ignoring comments, key order and equivalent intrinsic spellings.
      module TemplateDiff
        module_function

        Report = Struct.new(:sections, :strict, keyword_init: true) do
          # False when every difference is cosmetic and the report is not strict.
          def different?
            sections.any? do |name, diff|
              if name == "Template"
                counted(diff).any?
              else
                !diff.added.empty? || !diff.removed.empty? || diff.changed.any? { |entity| counted(entity.changes).any? }
              end
            end
          end

          def counted(changes) = strict ? changes : changes.reject(&:cosmetic)
        end

        def diff(before, after, strict: false)
          Report.new(sections: Comparer.compare(Loader.load(before), Loader.load(after)), strict: strict)
        end

        def diff_files(before_path, after_path, strict: false)
          Report.new(
            sections: Comparer.compare(Loader.load_file(before_path), Loader.load_file(after_path)),
            strict:   strict
          )
        end

        # One line per entity: `+` added, `-` removed, `~` changed; `no differences` when none.
        def render(report)
          lines = report.sections.flat_map do |name, diff|
            name == "Template" ? template_lines(report, diff) : section_lines(report, name, diff)
          end
          return "no differences\n" if lines.empty?

          note = report.different? ? [] : ["", "only cosmetic differences; --strict counts them"]
          "#{(lines + note).join("\n")}\n"
        end

        # Top-level keys: `different` and one entry per section.
        def render_json(report)
          sections = report.sections.to_h do |name, diff|
            [name, name == "Template" ? diff.map { |change| change_hash(change) } : section_hash(diff)]
          end
          JSON.pretty_generate("different" => report.different?, "sections" => sections)
        end

        def template_lines(report, changes)
          return [] if changes.empty?

          ["Template"] + changes.flat_map { |change| change_lines(change, report, "  ") }
        end
        private_class_method :template_lines

        def section_lines(report, name, diff)
          return [] if diff.empty?

          [name] +
            diff.added.map { |id, type| "  + #{id}#{" (#{type})" if type}" } +
            diff.removed.map { |id, type| "  - #{id}#{" (#{type})" if type}" } +
            diff.changed.flat_map { |entity| entity_lines(entity, report) }
        end
        private_class_method :section_lines

        def entity_lines(entity, report)
          head = "  ~ #{entity.name}#{" (#{entity.type})" if entity.type}#{'  REPLACEMENT: the type changed' if entity.replaced}"
          [head] + entity.changes.flat_map { |change| change_lines(change, report, "      ") }
        end
        private_class_method :entity_lines

        def change_lines(change, report, indent)
          marker = change.cosmetic && !report.strict ? " (cosmetic)" : ""
          case change.kind
          when :added then ["#{indent}+ #{change.path}: #{show(change.after)}"]
          when :removed then ["#{indent}- #{change.path}: #{show(change.before)}"]
          when :reordered then ["#{indent}~ #{change.path}: order #{show(change.before)} -> #{show(change.after)}#{marker}"]
          else ["#{indent}~ #{change.path}: #{show(change.before)} -> #{show(change.after)}#{marker}"]
          end
        end
        private_class_method :change_lines

        def show(value)
          text = value.is_a?(String) ? value.inspect : JSON.generate(value)
          text.length > 140 ? "#{text[0, 137]}..." : text
        end
        private_class_method :show

        def section_hash(diff)
          {
            "added"   => diff.added.map { |id, type| { "id" => id, "type" => type }.compact },
            "removed" => diff.removed.map { |id, type| { "id" => id, "type" => type }.compact },
            "changed" => diff.changed.map { |entity| entity_hash(entity) }
          }
        end
        private_class_method :section_hash

        def entity_hash(entity)
          changes = entity.changes.map { |change| change_hash(change) }
          { "id" => entity.name, "type" => entity.type, "replaced" => entity.replaced, "changes" => changes }.compact
        end
        private_class_method :entity_hash

        def change_hash(change)
          { "path" => change.path, "kind" => change.kind.to_s, "before" => change.before, "after" => change.after,
"cosmetic" => change.cosmetic }.compact
        end
        private_class_method :change_hash
      end
    end
  end
end
