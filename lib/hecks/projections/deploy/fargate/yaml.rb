module Hecks
  module Projections
    module Deploy
      module Fargate
        # Text helpers the Fargate template generator renders YAML with.
        #
        # The template is built as text, not as a data structure, so the comments
        # that explain each resource survive into the generated file.
        module Yaml
          module_function

          # Writes one value as a YAML scalar; a leading `!` marks a CloudFormation
          # intrinsic (`!Ref`, `!Sub`, `!GetAtt`) and is left unquoted.
          def scalar(value)
            case value
            when true, false, Integer, Float then value.to_s
            else
              text = value.to_s
              text.start_with?("!") ? text : text.to_json
            end
          end

          # Writes a value as a scalar that must stay a string, quoting a number
          # where `scalar` would leave it bare.
          def string(value)
            text = value.to_s
            text.start_with?("!") ? text : text.to_json
          end

          # Writes a list as a YAML flow sequence, rendering each item with `scalar`
          # unless it is a bare word, so a numeric-looking string stays quoted.
          def flow_list(values)
            "[#{values.map { |value| plain_word?(value) ? value : scalar(value) }.join(", ")}]"
          end

          def plain_word?(value)
            value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z0-9_.-]*\z/) && !%w[true false null yes no on
                                                                                      off].include?(value.downcase)
          end
          private_class_method :plain_word?

          # Indents every non-blank line of a block; blank lines stay empty.
          def indent(text, base)
            text.each_line.map { |line| line.strip.empty? ? line : "#{base}#{line}" }.join
          end

          # Replaces one `# TMPL:<marker>` line of a template with a block, indented
          # to the marker's own level; an empty block removes the marker line.
          def splice(template, marker, text)
            template.sub(/^([ \t]*)# TMPL:#{Regexp.escape(marker)}\n/) do
              text.empty? ? "" : indent(text, Regexp.last_match(1))
            end
          end

          # Turns a name such as `mock-payments` into a CloudFormation-safe
          # logical id part: `MockPayments`.
          def camel(name)
            name.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map { |part| part[0].upcase + part[1..] }.join
          end

          # Finds keys declared more than once at one indentation in a section, since
          # YAML loaders silently keep the last and drop the others.
          def duplicate_keys(section, indent: 2)
            keys = section.scan(/^ {#{indent}}([A-Za-z0-9]+):(?:\s|$)/).flatten
            keys.tally.select { |_key, count| count > 1 }.keys
          end
        end
      end
    end
  end
end
