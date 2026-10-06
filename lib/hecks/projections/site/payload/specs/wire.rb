# frozen_string_literal: true

require "json"

module Hecks
  module Projections
    module Site
      module Payload
        module Specs
          # The TypeScript for how an aggregate's attributes cross the wire: the lines that read
          # each one from the host's state, and the lines that write each one from an input.
          module Wire
            module_function

            def others(agg) = agg.attrs.reject { |attr| attr.name == agg.identity }

            def reads(agg)
              others(agg).map { |attr| "      #{attr.ts}: #{read(agg, attr)}," }.join("\n")
            end

            def read(agg, attr)
              return "#{Specs.reader(agg, attr)}(s.#{attr.name})" if attr.shape == :composite
              return "unwrapList(s.#{attr.name})" if attr.list
              return "whole(s.#{attr.name}, #{attr.wire_key.to_json})" if attr.shape == :integer

              attr.optional ? "orNull(s.#{attr.name})" : "orNull(s.#{attr.name}) ?? \"\""
            end

            def writes(agg)
              others(agg).map { |attr| "    #{write(attr)}," }.join("\n")
            end

            def write(attr)
              name = attr.name
              case attr.shape
              when :composite then composite_write(attr)
              when :integer then optional_write(attr, "{ #{attr.wire_key}: input.#{attr.ts} }", "input.#{attr.ts} != null")
              else
                return "#{name}: list(input.#{attr.ts})" if attr.list

                scalar_write(attr)
              end
            end

            def composite_write(attr)
              parts = attr.parts.map { |part| "#{part.name}: item.#{part.ts}" }.join(", ")
              "#{attr.name}: input.#{attr.ts}.map((item) => ({ #{parts} }))"
            end

            def scalar_write(attr)
              if attr.wire_key == "value"
                return "#{attr.name}: wrapped(input.#{attr.ts})" unless attr.optional

                return "...optionalValue(#{attr.name.to_json}, input.#{attr.ts})"
              end
              optional_write(attr, "{ #{attr.wire_key}: input.#{attr.ts} }", "input.#{attr.ts}")
            end

            def optional_write(attr, wire, present)
              return "#{attr.name}: #{wire}" unless attr.optional

              "...(#{present} ? { #{attr.name}: #{wire} } : {})"
            end
          end
        end
      end
    end
  end
end
