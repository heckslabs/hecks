# frozen_string_literal: true

require "json"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # JSON indented two spaces, with an empty list or object as `[]` or `{}`. It does not use
        # `JSON.pretty_generate`, whose spelling of an empty list depends on which JSON extensions
        # are loaded, so the projection's text is the same wherever it runs.
        module Pretty
          module_function

          # @param value [Object] a hash, array, string, number, boolean or nil
          # @param depth [Integer] the indentation level of the line the value starts on
          # @return [String] the value as indented JSON
          def generate(value, depth = 0)
            case value
            when Hash then block("{", "}", value.map { |key, item| member(key, item, depth) }, depth)
            when Array then block("[", "]", value.map { |item| generate(item, depth + 1) }, depth)
            else JSON.generate(value)
            end
          end

          # @return [String] one `"key": value` line of an object
          def member(key, item, depth) = "#{JSON.generate(key.to_s)}: #{generate(item, depth + 1)}"

          # @return [String] the lines between `open` and `close`, each indented under `depth`
          def block(open, close, lines, depth)
            return "#{open}#{close}" if lines.empty?

            pad = "  " * (depth + 1)
            "#{open}\n#{lines.map { |line| "#{pad}#{line}" }.join(",\n")}\n#{"  " * depth}#{close}"
          end
        end
      end
    end
  end
end
