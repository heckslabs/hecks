module Hecksagain
  module Bluebook
    module Expression
      module CanonicalForm
        Rule = Struct.new(:strategy, :source_token, :replacement, :boundary, :position, keyword_init: true)

        STRATEGIES = %w[collapse_whitespace replace].freeze

        RULES = [
          Rule.new(strategy: "collapse_whitespace", source_token: "", replacement: "", boundary: "none", position: 1),
          Rule.new(strategy: "replace", source_token: ".length", replacement: ".size", boundary: "word", position: 2)
        ].freeze

        module_function

        def table
          RULES.sort_by(&:position).map do |rule|
            {
              strategy:     rule.strategy,
              source_token: rule.source_token,
              replacement:  rule.replacement,
              boundary:     rule.boundary,
              position:     rule.position.to_s
            }
          end
        end

        def apply(source)
          RULES.sort_by(&:position).reduce(source.to_s) { |text, rule| step(text, rule) }.strip
        end

        def step(text, rule)
          case rule.strategy
          when "collapse_whitespace" then text.gsub(/\s+/, " ")
          when "replace"             then replace(text, rule)
          else
            raise ArgumentError, "#{rule.strategy.inspect} is not a linked normalisation strategy"
          end
        end

        def replace(text, rule)
          return text.gsub(rule.source_token, rule.replacement) if rule.boundary == "none"

          text.gsub(/#{Regexp.escape(rule.source_token)}(?![[:alnum:]_])/, rule.replacement)
        end
      end
    end
  end
end
