module Hecks
  module Projections
    module Deploy
      module TemplateDiff
        # Walks two normalized values side by side and appends a `Comparer::Change` for each
        # difference: hashes by key, lists of mappings by an identity field, other lists by
        # position.
        module ValueDiff
          module_function

          IDENTITY_KEYS = %w[Name Id Key PolicyName PathPattern HeaderName ContainerName Sid Field].freeze
          ORDERED_BY = %w[PathPattern].freeze
          SCALAR_TYPES = [String, Integer, Float, TrueClass, FalseClass].freeze

          # @param path [String] where the two values sit, dotted from the template root
          # @param before [Object] the value before
          # @param after [Object] the value after
          # @param changes [Array<Comparer::Change>] receives one entry per difference
          # @return [void]
          def diff_values(path, before, after, changes)
            return if before == after

            if before.is_a?(Hash) && after.is_a?(Hash)
              diff_hashes(path, before, after, changes)
            elsif before.is_a?(Array) && after.is_a?(Array)
              diff_arrays(path, before, after, changes)
            else
              changes << Comparer::Change.new(path: path, kind: :changed, before: before, after: after,
                                              cosmetic: same_text?(before, after))
            end
          end

          def diff_hashes(path, before, after, changes)
            (before.keys | after.keys).sort.each do |key|
              child = path.empty? ? key : "#{path}.#{key}"
              diff_member(child, slot(before, key), slot(after, key), changes)
            end
          end
          private_class_method :diff_hashes

          # A member present on one side only is added or removed; on both sides it is compared.
          # A side is a one-element list holding the member, or nil when it is absent.
          def diff_member(child, before, after, changes)
            return changes << Comparer::Change.new(path: child, kind: :removed, before: before.first) unless after
            return changes << Comparer::Change.new(path: child, kind: :added, after: after.first) unless before

            diff_values(child, before.first, after.first, changes)
          end
          private_class_method :diff_member

          def slot(hash, key)
            [hash[key]] if hash.key?(key)
          end
          private_class_method :slot

          def diff_arrays(path, before, after, changes)
            key = identity_key(before, after)
            return diff_keyed(path, key, before, after, changes) if key
            return changes << reordered(path, before, after, true) if before.sort_by(&:to_s) == after.sort_by(&:to_s)

            diff_positional(path, before, after, changes)
          end
          private_class_method :diff_arrays

          def diff_positional(path, before, after, changes)
            (0...[before.size, after.size].max).each do |index|
              diff_member("#{path}[#{index}]", at(before, index), at(after, index), changes)
            end
          end
          private_class_method :diff_positional

          def at(list, index)
            [list[index]] if index < list.size
          end
          private_class_method :at

          def diff_keyed(path, key, before, after, changes)
            left = by_identity(before, key)
            right = by_identity(after, key)
            (left.keys | right.keys).each do |name|
              diff_member("#{path}[#{key}=#{name}]", slot(left, name), slot(right, name), changes)
            end
            check_order(path, key, left.keys, right.keys, changes)
          end
          private_class_method :diff_keyed

          def by_identity(list, key)
            list.to_h { |item| [item[key].to_s, item] }
          end
          private_class_method :by_identity

          def check_order(path, key, left, right, changes)
            return unless ORDERED_BY.include?(key)

            common = left & right
            return if left.select { |name| common.include?(name) } == right.select { |name| common.include?(name) }

            changes << reordered(path, left, right, false)
          end
          private_class_method :check_order

          def reordered(path, before, after, cosmetic)
            Comparer::Change.new(path: path, kind: :reordered, before: before, after: after, cosmetic: cosmetic)
          end
          private_class_method :reordered

          # A list of mappings is matched by a field only when every entry in both lists has it and
          # no two entries share its value, so a match is never ambiguous.
          def identity_key(before, after)
            lists = [before, after]
            return nil if lists.any? { |list| list.empty? || !list.all?(Hash) }

            IDENTITY_KEYS.find { |key| lists.all? { |list| identifies?(list, key) } }
          end
          private_class_method :identity_key

          def identifies?(list, key)
            list.all? { |item| scalar?(item[key]) } && list.map { |item| item[key].to_s }.uniq.size == list.size
          end
          private_class_method :identifies?

          def scalar?(value)
            value.is_a?(String) || value.is_a?(Integer)
          end
          private_class_method :scalar?

          def same_text?(before, after)
            scalars = [before, after].all? { |value| SCALAR_TYPES.any? { |type| value.is_a?(type) } }
            scalars && before.to_s == after.to_s
          end
          private_class_method :same_text?
        end
      end
    end
  end
end
