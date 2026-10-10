# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # A list of mixed blocks, found by shape: a `list_of` value object that has a discriminator,
        # a part that is one of a closed set of kinds. The editor draws it as ordered cards.
        #
        # The discriminator is a part whose type is a closed set (`one_of`) of one plain value, or,
        # failing that, a text part that an invariant restricts to a literal list
        # (`["a", "b"].include?(kind)`). A value object that holds `spans` is a body's block, which
        # the rich-text widget edits, and is never a block list.
        #
        # Which slots each kind uses is read from a declared table: a closed set of rows with the
        # parts `kind`, `requires` and `uses` whose kinds are among the discriminator's. With no
        # such table every slot is shown, and the invariants that name a kind only hint which slots
        # it reads. A limit is read from an invariant or given of the form `<list>.size <= <n>`.
        module Blocks
          # The parts a table of rules must have.
          RULE_PARTS = %w[kind requires uses].freeze

          # The parts that make a value object's picture, in the vocabulary of a body's image block.
          PICTURE = { "key" => "media_ref", "alt" => "alt", "caption" => "caption" }.freeze

          # An invariant that restricts a text part to a literal list of kinds.
          LITERALS = /\A\[((?:"[^"]+"(?:, )?)+)\]\.include\?\((\w+)\)\z/

          # An invariant that holds unless the kind is the named one: what the rest of it reads.
          GUARD = /\A(\w+)(?:\.value)? != "([^"]+)" \|\| (.*)\z/m

          # A limit written as a size comparison.
          LIMIT = /\A(\w+)\.size <= (\d+)\z/

          module_function

          # @param attribute [Bluebook::Attribute] a declared attribute
          # @param objects [Hash{String => Bluebook::ValueObject}] the aggregate's value objects
          # @return [Hash{String => Object}, nil] the block list the attribute is, or nil
          def of(attribute, objects)
            item = objects[attribute.type.to_s]
            return nil unless attribute.list? && item && !body_block?(item)

            found = discriminator(item, objects)
            found && describe(item, objects, *found)
          end

          # @return [Boolean] whether the value object holds `spans`, as a body's block does
          def body_block?(item) = item.attributes.any? { |part| part.name.to_s == "spans" }

          # @return [Array(String, Array<String>), nil] the part and the kinds it is one of
          def discriminator(item, objects)
            closed(item, objects) || literal(item)
          end

          # @return [Array(String, Array<String>), nil] a part typed as a closed set of plain values
          def closed(item, objects)
            item.attributes.each do |part|
              kinds = members_of(objects[part.type.to_s]) unless part.list?
              return [part.name.to_s, kinds] if kinds && !kinds.empty?
            end
            nil
          end

          # @return [Array<String>, nil] the values of a closed set of one plain part
          def members_of(set)
            return nil unless set&.closed_set? && set.attributes.size == 1

            set.members.filter_map { |member| member[set.attributes.first.name]&.to_s }
          end

          # @return [Array(String, Array<String>), nil] a text part restricted by a literal list
          def literal(item)
            found = literals(item).find { |match| item.attributes.any? { |part| part.name.to_s == match[2] && !part.list? } }
            found && [found[2], found[1].scan(/"([^"]+)"/).flatten]
          end

          # @return [Array<MatchData>] the invariants that restrict a part to a literal list
          def literals(item) = item.invariants.filter_map { |rule| LITERALS.match(rule.canonical.to_s) }

          def describe(item, objects, name, kinds)
            table = rules(objects, kinds)
            found = { "discriminator" => name, "kinds" => kinds, "limits" => limits(item), "pictures" => pictures(item, objects) }
            found["rules"] = table if table
            found["mentions"] = mentions(item, name, kinds) unless table
            found.reject { |_, value| value.respond_to?(:empty?) && value.empty? }
          end

          # @return [Hash{String => Hash}, nil] each kind's `requires` and `uses`, from the table
          def rules(objects, kinds)
            table = objects.values.find { |object| ruled?(object, kinds) }
            return nil unless table

            table.members.to_h { |row| [row[:kind].to_s, { "requires" => words(row[:requires]), "uses" => words(row[:uses]) }] }
          end

          def ruled?(object, kinds)
            object.closed_set? && (RULE_PARTS - object.attributes.map { |part| part.name.to_s }).empty? &&
              object.members.all? { |row| kinds.include?(row[:kind].to_s) }
          end

          def words(text) = text.to_s.split(",").map(&:strip).reject(&:empty?)

          # @return [Hash{String => Array<String>}] the slots each kind's guarded invariants read
          def mentions(item, name, kinds)
            parts = item.attributes.map { |part| part.name.to_s } - [name]
            guarded(item, name).each_with_object({}) do |(kind, rest), found|
              next unless kinds.include?(kind)

              found[kind] = ((found[kind] || []) | parts.select { |part| rest.match?(/\b#{Regexp.escape(part)}\b/) })
            end
          end

          def guarded(item, name)
            item.invariants.filter_map do |rule|
              match = GUARD.match(rule.canonical.to_s)
              [match[2], match[3]] if match && match[1] == name
            end
          end

          # @return [Hash{String => Integer}] each list part of the item and its declared maximum
          def limits(item)
            item.invariants.filter_map do |rule|
              match = LIMIT.match(rule.canonical.to_s)
              [match[1], match[2].to_i] if match
            end.to_h
          end

          # @param commands [Array<Bluebook::Command>] the aggregate's commands
          # @param name [String] a list attribute's name
          # @return [Integer, nil] the most the list may hold, from a command's `given`
          def maximum(commands, name)
            sizes = commands.flat_map(&:givens).filter_map do |rule|
              match = LIMIT.match(rule.canonical.to_s)
              match[2].to_i if match && match[1] == name
            end
            sizes.min
          end

          # @return [Hash{String => Hash}] the value object and each value object its lists hold,
          #   to the parts that name a picture, for those that have the parts
          def pictures(item, objects)
            held = item.attributes.select(&:list?).filter_map { |part| objects[part.type.to_s] }
            [item, *held].filter_map { |object| (found = picture(object)) && [object.hecks_name, found] }.to_h
          end

          def picture(object)
            names = object.attributes.reject(&:list?).map { |part| part.name.to_s }
            return nil unless names.include?(PICTURE["key"]) && names.include?(PICTURE["alt"])

            PICTURE.select { |_, part| names.include?(part) }
          end
        end
      end
    end
  end
end
