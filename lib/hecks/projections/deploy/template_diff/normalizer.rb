module Hecks
  module Projections
    module Deploy
      module TemplateDiff
        # Rewrites a loaded CloudFormation template into one canonical spelling so two templates
        # that say the same thing compare equal: `DependsOn` sorted, and a `!Sub` of a single
        # variable written as the `!Ref` or `!GetAtt` it stands for.
        module Normalizer
          module_function

          # @param value [Object] a loaded template, or any node inside one
          # @return [Object] the same shape with every node in its canonical spelling
          def normalize(value)
            case value
            when Hash then normalize_hash(value)
            when Array then value.map { |item| normalize(item) }
            else value
            end
          end

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

            intrinsic_for(match[1])
          end
          private_class_method :simplify_sub

          def intrinsic_for(name)
            return { "Ref" => name } unless name.include?(".") && !name.start_with?("AWS::")

            { "Fn::GetAtt" => name.split(".", 2) }
          end
          private_class_method :intrinsic_for
        end
      end
    end
  end
end
