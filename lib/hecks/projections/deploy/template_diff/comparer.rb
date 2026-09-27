module Hecks
  module Projections
    module Deploy
      module TemplateDiff
        # Compares two loaded CloudFormation templates.
        #
        # Resources, parameters, outputs, conditions and mappings are matched
        # by name, then compared property by property. A list of mappings that
        # each carry a `Name`, `Id`, `Key` or similar field (container
        # definitions, environment variables, tags, origins) is matched by that
        # field, not by position, so inserting one entry reports one addition
        # instead of a cascade of shifted values. Cache behaviors are matched
        # the same way but their order is also checked, because CloudFront
        # takes the first pattern that matches.
        #
        # Two values that differ only in how they are written (a number and
        # the same digits as text, a `!Sub` with nothing but one `${Name}` and
        # a `!Ref Name`) are equal after normalization or marked `cosmetic`.
        module Comparer
          module_function

          Change = Struct.new(:path, :kind, :before, :after, :cosmetic, keyword_init: true)
          Entity = Struct.new(:name, :type, :changes, :replaced, keyword_init: true)
          SectionDiff = Struct.new(:added, :removed, :changed, keyword_init: true) do
            # Tells whether nothing in the section differs.
            #
            # @return [Boolean] true when no entity was added, removed or changed
            def empty? = added.empty? && removed.empty? && changed.empty?
          end

          ENTITY_SECTIONS = %w[Parameters Resources Outputs Conditions Mappings].freeze
          IDENTITY_KEYS = %w[Name Id Key PolicyName PathPattern HeaderName ContainerName Sid Field].freeze
          ORDERED_BY = %w[PathPattern].freeze

          # Compares two templates.
          #
          # @param before [Hash{String => Object}] the template as `Loader.load` returns it
          # @param after [Hash{String => Object}] the template to compare it with
          # @return [Hash{String => SectionDiff, Array<Change>}] one `SectionDiff` per entity
          #   section
          #   that either template has, and `"Template"` mapped to the changes in every other
          #   top-level key such as `Description`
          def compare(before, after)
            before = normalize(before)
            after = normalize(after)
            diff = ENTITY_SECTIONS.each_with_object({}) do |section, sections|
              next unless before.key?(section) || after.key?(section)

              sections[section] = section_diff(section, before[section] || {}, after[section] || {})
            end
            diff["Template"] = template_changes(before, after)
            diff
          end

          def normalize(value)
            case value
            when Hash then normalize_hash(value)
            when Array then value.map { |item| normalize(item) }
            else value
            end
          end
          private_class_method :normalize

          def normalize_hash(hash)
            result = hash.to_h { |key, item| [key, key == "DependsOn" ? depends_on(item) : normalize(item)] }
            substitution?(result) ? simplify_sub(result) : result
          end
          private_class_method :normalize_hash

          def depends_on(value)
            Array(value).map(&:to_s).sort
          end
          private_class_method :depends_on

          def substitution?(hash)
            hash.size == 1 && hash["Fn::Sub"].is_a?(String)
          end
          private_class_method :substitution?

          # `!Sub "${Name}"` is `!Ref Name`, `!Sub "${A.B}"` is `!GetAtt A.B`, and a `!Sub` with no
          # variable is the plain string.
          def simplify_sub(hash)
            text = hash["Fn::Sub"]
            return text unless text.include?("${")

            match = text.match(/\A\$\{([^}!]+)\}\z/)
            return hash unless match

            name = match[1]
            name.include?(".") && !name.start_with?("AWS::") ? { "Fn::GetAtt" => name.split(".", 2) } : { "Ref" => name }
          end
          private_class_method :simplify_sub

          def section_diff(section, before, after)
            SectionDiff.new(
              added:   (after.keys - before.keys).sort.map { |name| [name, type_of(section, after[name])] },
              removed: (before.keys - after.keys).sort.map { |name| [name, type_of(section, before[name])] },
              changed: (before.keys & after.keys).sort.filter_map { |name| entity_diff(section, name, before[name], after[name]) }
            )
          end
          private_class_method :section_diff

          def type_of(section, entity)
            entity.is_a?(Hash) && %w[Resources Parameters].include?(section) ? entity["Type"] : nil
          end
          private_class_method :type_of

          def entity_diff(section, name, before, after)
            return nil if before == after

            changes = []
            diff_values("", before, after, changes)
            return nil if changes.empty?

            replaced = section == "Resources" && before.is_a?(Hash) && after.is_a?(Hash) && before["Type"] != after["Type"]
            Entity.new(name: name, type: type_of(section, after), changes: changes, replaced: replaced)
          end
          private_class_method :entity_diff

          def template_changes(before, after)
            changes = []
            others = (before.keys | after.keys) - ENTITY_SECTIONS
            others.sort.each { |key| diff_values(key, before[key], after[key], changes) unless before[key] == after[key] }
            changes
          end
          private_class_method :template_changes

          def diff_values(path, before, after, changes)
            return if before == after

            if before.is_a?(Hash) && after.is_a?(Hash)
              diff_hashes(path, before, after, changes)
            elsif before.is_a?(Array) && after.is_a?(Array)
              diff_arrays(path, before, after, changes)
            else
              changes << Change.new(path: path, kind: :changed, before: before, after: after, cosmetic: same_text?(before, after))
            end
          end
          private_class_method :diff_values

          def diff_hashes(path, before, after, changes)
            (before.keys | after.keys).sort.each do |key|
              child = path.empty? ? key : "#{path}.#{key}"
              if !after.key?(key)
                changes << Change.new(path: child, kind: :removed, before: before[key])
              elsif !before.key?(key)
                changes << Change.new(path: child, kind: :added, after: after[key])
              else
                diff_values(child, before[key], after[key], changes)
              end
            end
          end
          private_class_method :diff_hashes

          def diff_arrays(path, before, after, changes)
            key = identity_key(before, after)
            return diff_keyed(path, key, before, after, changes) if key
            if before.sort_by(&:to_s) == after.sort_by(&:to_s)
              return changes << Change.new(path: path, kind: :reordered, before: before, after: after,
                                           cosmetic: true)
            end

            (0...[before.size, after.size].max).each do |index|
              child = "#{path}[#{index}]"
              if index >= after.size then changes << Change.new(path: child, kind: :removed, before: before[index])
              elsif index >= before.size then changes << Change.new(path: child, kind: :added, after: after[index])
              else diff_values(child, before[index], after[index], changes)
              end
            end
          end
          private_class_method :diff_arrays

          def diff_keyed(path, key, before, after, changes)
            left = before.to_h { |item| [item[key].to_s, item] }
            right = after.to_h { |item| [item[key].to_s, item] }
            (left.keys | right.keys).each do |name|
              child = "#{path}[#{key}=#{name}]"
              if !right.key?(name) then changes << Change.new(path: child, kind: :removed, before: left[name])
              elsif !left.key?(name) then changes << Change.new(path: child, kind: :added, after: right[name])
              else diff_values(child, left[name], right[name], changes)
              end
            end
            check_order(path, key, left.keys, right.keys, changes)
          end
          private_class_method :diff_keyed

          def check_order(path, key, left, right, changes)
            return unless ORDERED_BY.include?(key)

            common = left & right
            return if left.select { |name| common.include?(name) } == right.select { |name| common.include?(name) }

            changes << Change.new(path: path, kind: :reordered, before: left, after: right, cosmetic: false)
          end
          private_class_method :check_order

          # A list of mappings is matched by a field only when every entry in both lists has it and
          # no two entries share its value, so a match is never ambiguous.
          def identity_key(before, after)
            lists = [before, after]
            return nil if lists.any? { |list| list.empty? || !list.all?(Hash) }

            IDENTITY_KEYS.find do |key|
              lists.all? do |list|
                list.all? { |item| scalar?(item[key]) } && list.map do |item|
                  item[key].to_s
                end.uniq.size == list.size
              end
            end
          end
          private_class_method :identity_key

          def scalar?(value)
            value.is_a?(String) || value.is_a?(Integer)
          end
          private_class_method :scalar?

          def same_text?(before, after)
            scalars = [before, after].all? do |value|
              [String, Integer, Float, TrueClass, FalseClass].any? do |type|
                value.is_a?(type)
              end
            end
            scalars && before.to_s == after.to_s
          end
          private_class_method :same_text?
        end
      end
    end
  end
end
