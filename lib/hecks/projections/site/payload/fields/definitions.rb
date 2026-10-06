# frozen_string_literal: true

require "json"

module Hecks
  module Projections
    module Site
      module Payload
        module Fields
          # The TypeScript literals of a collection's field definitions: one `{ name, type, ... }`
          # for a scalar, an array field for a list, and an array of sub-fields for a composite.
          module Definitions
            module_function

            # @return [Array<Array<String>>] the `[key, value]` pairs of a scalar field's literal
            def base(attr, row, name, required)
              kind = Fields.kind_of(attr, row)
              required = row[:required] if row.key?(:required)
              pairs = [["name", name.to_json], ["type", KINDS.fetch(kind).to_json]]
              pairs << ["required", "true"] if required
              pairs << ["unique", "true"] if attr.name == "slug"
              pairs << ["defaultValue", row[:default].to_json] if row[:default]
              pairs.concat(extras(kind, row))
            end

            def extras(kind, row, describe: true)
              pairs = []
              pairs << ["options", options(row[:options])] if kind == "select" && row[:options]
              pairs << ["relationTo", row[:relation].to_json] if row[:relation]
              admin = admin_pairs(kind, row, describe)
              pairs << ["admin", "{ #{admin.map { |key, value| "#{key}: #{value}" }.join(", ")} }"] if admin.any?
              pairs
            end

            def admin_pairs(kind, row, describe)
              admin = []
              admin << ["description", row[:description].to_json] if describe && row[:description]
              if KINDS[kind] == "date"
                admin << ["date",
                          "{ pickerAppearance: #{(kind == "day" ? "dayOnly" : "dayAndTime").to_json} }"]
              end
              admin
            end

            def options(text)
              items = text.split(",").map(&:strip).reject(&:empty?).map do |item|
                value, label = item.split("=", 2)
                label ? "{ label: #{label.to_json}, value: #{value.to_json} }" : value.to_json
              end
              "[#{items.join(", ")}]"
            end

            def literal(pairs) = "{ #{pairs.map { |key, value| "#{key}: #{value}" }.join(", ")} }"

            def array(_attr, row, name)
              kind = row[:kind] || "text"
              element = literal([["name", '"value"'], ["type", KINDS.fetch(kind).to_json], ["required", "true"],
                                 *extras(kind, row, describe: false)])
              array_literal(name, row, "[#{element}]")
            end

            def composite(attr, row, name, rows)
              subs = attr.parts.map { |part| sub_field(attr, part, rows) }
              array_literal(name, row, "[#{subs.join(", ")}]")
            end

            def sub_field(attr, part, rows)
              part_row = Fields.row_for(rows, attr.name, part.name)
              literal(base(part, part_row.merge(required: part_row.fetch(:required, true)), part.ts, true))
            end

            # An array field named `name`, with the labels and description its row gives.
            def array_literal(name, row, fields)
              pairs = [["name", name.to_json], ["type", '"array"']]
              pairs << ["labels", labels(row[:label])] if row[:label]
              pairs << ["admin", "{ description: #{row[:description].to_json} }"] if row[:description]
              pairs << ["fields", fields]
              literal(pairs)
            end

            def labels(text)
              singular, plural = text.split("|", 2)
              "{ singular: #{singular.to_json}, plural: #{(plural || "#{singular}s").to_json} }"
            end
          end
        end
      end
    end
  end
end
