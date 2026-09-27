require "json"
require_relative "template_diff/loader"
require_relative "template_diff/comparer"

module Hecks
  module Projections
    module Deploy
      # An offline comparison of two CloudFormation templates.
      #
      # It answers "what would change if this template replaced that one"
      # from the two files alone, the offline half of checking that a
      # generated template leaves a live stack untouched: when the generated
      # template and the one already deployed differ in nothing but comments,
      # ordering and spelling, a change set against the live stack should be
      # empty too. It reads no AWS state and changes nothing.
      #
      # ## What it reports
      #
      # Resources, parameters, outputs, conditions and mappings that were
      # added, removed or changed, by logical id, and for a changed one every
      # property that differs, with the value before and after. Other
      # top-level keys, such as `Description`, are compared as values.
      # Comments and the order of keys do not count, and the short and long
      # forms of an intrinsic (`!Ref Name`, `{"Ref": "Name"}`) are the same
      # thing. A change to a resource's `Type` is marked as a replacement.
      # Differences that are only in how a value is written are marked
      # cosmetic and do not count as a difference unless `strict` is set.
      #
      # ## What it does not do
      #
      # It does not know which property changes CloudFormation applies in
      # place and which replace the resource beyond a change of `Type`, so a
      # changed immutable property is listed as a change, not flagged.
      module TemplateDiff
        module_function

        Report = Struct.new(:sections, :strict, keyword_init: true) do
          # Tells whether the two templates differ in a way that counts.
          #
          # @return [Boolean] false when every difference is cosmetic and the report is not strict
          def different?
            sections.any? do |name, diff|
              if name == "Template"
                counted(diff).any?
              else
                !diff.added.empty? || !diff.removed.empty? || diff.changed.any? { |entity| counted(entity.changes).any? }
              end
            end
          end

          # Keeps the changes that count towards a difference.
          #
          # @param changes [Array<Comparer::Change>] the changes to filter
          # @return [Array<Comparer::Change>] every change, or only the non-cosmetic ones unless
          #   strict
          def counted(changes) = strict ? changes : changes.reject(&:cosmetic)
        end

        # Compares two template texts.
        #
        # @param before [String] the first template, YAML
        # @param after [String] the second template, YAML
        # @param strict [Boolean] whether cosmetic differences count as differences
        # @return [Report] the differences, by section
        # @raise [ArgumentError] if either text is not a valid template
        def diff(before, after, strict: false)
          Report.new(sections: Comparer.compare(Loader.load(before), Loader.load(after)), strict: strict)
        end

        # Compares two template files.
        #
        # @param before_path [String] the path of the first template
        # @param after_path [String] the path of the template to compare it with
        # @param strict [Boolean] whether cosmetic differences count as differences
        # @return [Report] the differences, by section
        # @raise [ArgumentError] if either file is missing or is not a valid template
        def diff_files(before_path, after_path, strict: false)
          Report.new(
            sections: Comparer.compare(Loader.load_file(before_path), Loader.load_file(after_path)),
            strict:   strict
          )
        end

        # Writes a report as text for a person to read.
        #
        # @param report [Report] the differences to describe
        # @return [String] one section per kind of entity, each entity on a `+`, `-` or `~` line,
        #   or `no differences` when nothing differs
        def render(report)
          lines = report.sections.flat_map do |name, diff|
            name == "Template" ? template_lines(report, diff) : section_lines(report, name, diff)
          end
          return "no differences\n" if lines.empty?

          note = report.different? ? [] : ["", "only cosmetic differences; --strict counts them"]
          "#{(lines + note).join("\n")}\n"
        end

        # Writes a report as JSON for a program to read.
        #
        # @param report [Report] the differences to describe
        # @return [String] a JSON document with `different` and one entry per section
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
