require "psych"

module Hecks
  module Projections
    module Deploy
      module TemplateDiff
        # Reads a CloudFormation template in YAML into plain Ruby data.
        #
        # CloudFormation's short forms (`!Ref Name`, `!GetAtt A.B`, `!Sub "..."`)
        # are YAML tags that a stock loader refuses or drops. This loader walks
        # the parsed document and turns each into the long form CloudFormation
        # itself reads (`{"Ref" => "Name"}`, `{"Fn::GetAtt" => ["A", "B"]}`), so
        # a template written with short forms and one written with long forms
        # load to the same data. Comments and key order do not survive loading,
        # which is what a comparison of two templates wants.
        #
        # Nothing here evaluates a template or contacts AWS.
        module Loader
          module_function

          # Turns template text into data.
          #
          # @param text [String] a CloudFormation template written in YAML
          # @return [Hash{String => Object}] the template, with intrinsic tags in their long form
          # @raise [ArgumentError] if the text is not one YAML mapping, or uses an alias
          def load(text)
            document = Psych.parse(text)
            raise ArgumentError, "the template is empty" unless document

            value = convert(document.root)
            raise ArgumentError, "a CloudFormation template is a mapping at the top level" unless value.is_a?(Hash)

            value
          rescue Psych::SyntaxError => e
            raise ArgumentError, "the template is not valid YAML: #{e.message}"
          end

          # Reads a template from a file.
          #
          # @param path [String] the path of a YAML template
          # @return [Hash{String => Object}] the template, as `load` returns it
          # @raise [ArgumentError] if the file is missing or is not a template
          def load_file(path)
            raise ArgumentError, "#{path} does not exist" unless File.file?(path)

            load(File.read(path))
          rescue ArgumentError => e
            raise if e.message.start_with?(path)

            raise ArgumentError, "#{path}: #{e.message}"
          end

          def convert(node)
            raise ArgumentError, "YAML aliases are not supported in a template" if node.is_a?(Psych::Nodes::Alias)

            value =
              case node
              when Psych::Nodes::Mapping then mapping(node)
              when Psych::Nodes::Sequence then node.children.map { |child| convert(child) }
              else scalar(node)
              end
            intrinsic?(node.tag) ? intrinsic(node.tag, value) : value
          end
          private_class_method :convert

          def mapping(node)
            node.children.each_slice(2).to_h { |key, value| [convert(key).to_s, convert(value)] }
          end
          private_class_method :mapping

          # A plain scalar is typed the way YAML types it (`8080` is a number, `true` a boolean); a
          # quoted or block scalar is always text.
          def scalar(node)
            return node.value unless node.plain && node.tag.nil?

            Psych::ScalarScanner.new(Psych::ClassLoader::Restricted.new([], [])).tokenize(node.value)
          end
          private_class_method :scalar

          def intrinsic?(tag)
            tag&.start_with?("!") && !tag.start_with?("!!")
          end
          private_class_method :intrinsic?

          def intrinsic(tag, value)
            name = tag.delete_prefix("!")
            case name
            when "Ref", "Condition" then { name => value }
            when "GetAtt" then { "Fn::GetAtt" => get_att(value) }
            else { "Fn::#{name}" => value }
            end
          end
          private_class_method :intrinsic

          # `!GetAtt A.B` is the short form of `["A", "B"]`; only the first dot separates the
          # resource from the attribute, since an attribute may itself contain dots.
          def get_att(value)
            value.is_a?(String) ? value.split(".", 2) : value
          end
          private_class_method :get_att
        end
      end
    end
  end
end
