# frozen_string_literal: true

require "json"

module Hecks
  module Projections
    module Site
      module Payload
        module Fields
          # The TypeScript expressions that read one saved document field back into the aggregate's
          # input: a scalar, a list, a related document, a date or a composite's rows.
          module Readers
            module_function

            def input(attr, row, rows)
              return composite_input(attr, rows) if attr.shape == :composite

              name = row[:field] || attr.ts
              kind = Fields.kind_of(attr, row)
              return list_input(name, kind) if attr.list

              scalar_input(attr, row, name, kind)
            end

            def list_input(name, kind) = "valuesOf(doc.#{name}, #{kind == "date" ? "isoOrNull" : "nonBlank"})"

            def scalar_input(attr, row, name, kind)
              case kind
              when "upload", "relationship" then related_input(row, name, kind)
              when "date", "day" then date_input(attr, name, kind)
              when "number" then number_input(attr, name)
              else attr.optional ? "nonBlank(doc.#{name})" : "String(doc.#{name})"
              end
            end

            def related_input(row, name, kind)
              via = row[:via] || (kind == "upload" ? "url" : "slug")
              "await related(req, #{row[:relation].to_json}, doc.#{name}, #{via.to_json})"
            end

            def number_input(attr, name)
              attr.optional ? "doc.#{name} == null ? null : Number(doc.#{name})" : "Number(doc.#{name})"
            end

            def date_input(attr, name, kind)
              return "isoOrNull(doc.#{name})#{' ?? ""' unless attr.optional}" unless attr.shape == :integer || kind == "day"

              stamp = "doc.#{name} ? new Date(doc.#{name} as string).getTime() : Date.now()"
              "Math.floor((#{stamp}) / 1000)"
            end

            def composite_input(attr, rows)
              parts = attr.parts.map do |part|
                "#{part.ts}: #{part_input(part, Fields.row_for(rows, attr.name, part.name))}"
              end.join(", ")
              "(Array.isArray(doc.#{attr.ts}) ? doc.#{attr.ts} : []).map((raw) => { const s = raw as Doc; return { #{parts} }; })"
            end

            def part_input(part, row)
              return "isoOrNull(s.#{part.ts}) ?? \"\"" if KINDS[row[:kind]] == "date"

              "nonBlank(s.#{part.ts}) ?? \"\""
            end
          end
        end
      end
    end
  end
end
