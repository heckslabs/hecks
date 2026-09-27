module Hecks
  module Projections
    module Deploy
      module Fargate
        # Text helpers the Fargate template generator renders YAML with.
        #
        # The template is built as text, not as a data structure, so the
        # comments that explain each resource survive into the generated file.
        # These helpers cover the three things text rendering needs: writing a
        # setting's value as a YAML scalar, indenting a flush-left block, and
        # splicing a block into a marker line of the surrounding template.
        module Yaml
          module_function

          # Writes one value as a YAML scalar.
          #
          # A string that starts with `!` is a CloudFormation intrinsic
          # (`!Ref Name`, `!Sub "..."`, `!GetAtt Name.Arn`) and is written
          # verbatim. Any other string is double-quoted, so a value such as
          # `"1"` stays a string. Numbers and booleans are written bare.
          #
          # @param value [String, Integer, Float, true, false] the value to render
          # @return [String] the YAML text for the value, on one line
          def scalar(value)
            case value
            when true, false, Integer, Float then value.to_s
            else
              text = value.to_s
              text.start_with?("!") ? text : text.to_json
            end
          end

          # Writes a value as a scalar that must stay a string.
          #
          # Environment values and container settings such as a port are
          # strings to `ECS` however they are typed in the world file, so a
          # number is quoted here where `scalar` would leave it bare.
          #
          # @param value [Object] the value to render
          # @return [String] the YAML text for the value, on one line
          def string(value)
            text = value.to_s
            text.start_with?("!") ? text : text.to_json
          end

          # Writes a list as a YAML flow sequence.
          #
          # A string made of a word (an id, an HTTP method) is left bare; any
          # other string is written with `scalar`, so a value YAML would read
          # as a number, a boolean or null stays a string.
          #
          # @param values [Array<Object>] the items, each rendered with `scalar` unless it is a
          #   plain word
          # @return [String] the `[a, b]` text
          def flow_list(values)
            "[#{values.map { |value| plain_word?(value) ? value : scalar(value) }.join(', ')}]"
          end

          def plain_word?(value)
            value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z0-9_.-]*\z/) && !%w[true false null yes no on
                                                                                      off].include?(value.downcase)
          end
          private_class_method :plain_word?

          # Indents every non-blank line of a block.
          #
          # @param text [String] the block to indent
          # @param base [String] the whitespace to put in front of each non-blank line
          # @return [String] the block, indented, with blank lines left empty
          def indent(text, base)
            text.each_line.map { |line| line.strip.empty? ? line : "#{base}#{line}" }.join
          end

          # Replaces one `# TMPL:<marker>` line of a template with a block.
          #
          # The block is written flush-left and takes the marker line's own
          # indentation. An empty block removes the marker line completely, so
          # a template that uses none of the optional sections renders exactly
          # as it did before those sections existed.
          #
          # @param template [String] the template holding the marker line
          # @param marker [String] the marker name, without the `# TMPL:` prefix
          # @param text [String] the flush-left block to splice in, ending in a newline or empty
          # @return [String] the template with the marker line replaced
          def splice(template, marker, text)
            template.sub(/^([ \t]*)# TMPL:#{Regexp.escape(marker)}\n/) do
              text.empty? ? "" : indent(text, Regexp.last_match(1))
            end
          end

          # Turns a name such as `mock-payments` into a CloudFormation-safe
          # logical id part: `MockPayments`.
          #
          # @param name [String] a name made of letters, digits, `_` and `-`
          # @return [String] the name in camel case, letters and digits only
          def camel(name)
            name.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map { |part| part[0].upcase + part[1..] }.join
          end

          # Finds keys declared more than once at one indentation in a section.
          #
          # YAML loaders keep the last of a repeated key without complaint, so
          # two resources given the same logical id would silently drop one.
          #
          # @param section [String] the text of a `Resources:` or `Parameters:` section
          # @param indent [Integer] the indentation of the keys to check
          # @return [Array<String>] the keys that appear more than once
          def duplicate_keys(section, indent: 2)
            keys = section.scan(/^ {#{indent}}([A-Za-z0-9]+):(?:\s|$)/).flatten
            keys.tally.select { |_key, count| count > 1 }.keys
          end
        end
      end
    end
  end
end
