require_relative "evaluator"
require_relative "resolver"
require_relative "ast_json/emitters"

module Hecks
  module Bluebook
    module Expression
      # Walks the Evaluator/Resolver AST and emits JSON-serializable Hashes tagged by `"op"`.
      # Lives in core because rust/host cannot link the kernel crate and interprets this from
      # ir.json.
      module AstJson
        module_function

        # The closed roster of `"op"` tags. A new node kind needs an entry here and an arm in
        # each walker and reader; unhandled nodes raise rather than being dropped.
        OPS = %w[
          or and not compare include
          int float str bool nil array lookup
          add modulo sign_test empty size to_s
          block_predicate find first last
          matches_regex presence assignment split starts_with ends_with
        ].freeze

        # One rule row: description, canonical text, and the AST derived from that text.
        def rule_row(rule)
          { description: rule.description, canonical: rule.canonical, ast: rule.ast || emit_predicate(rule.canonical) }
        end

        # Parses `canonical` and emits its JSON AST in one step.
        def emit_predicate(canonical)
          emit_bool(Evaluator.parse(canonical))
        end

        # Holds every `.match?` pattern a rule carries to `PatternSubset`, as an attribute's
        # `pattern:` is; walking the AST gives every rule site the one check.
        #
        # @raise [Bluebook::DSL::Malformed] if a `matches_regex` pattern is outside `PatternSubset`
        def refuse_unshared_patterns!(ast, owner:, word:)
          return ast if Hecks::Bluebook::MetaValidator.shadow_parsing? # frozen era text is history

          each_node(ast) do |node|
            next unless node["op"] == "matches_regex"

            rejection = PatternSubset.validate(node["pattern"])
            next unless rejection

            raise DSL::Malformed,
                  "#{owner}'s #{word} matches against #{node["pattern"].inspect}, which uses a " \
                  "#{rejection.construct} — #{rejection.reason}"
          end
          ast
        end

        # What a `lookup` path can never contain: a call's parentheses, or an argument list's
        # commas and spaces.
        #
        # A bare `?` is deliberately not in the set: `x.nil?` also parses as a lookup, loads, and
        # evaluates without raising, and real bluebooks declare it.
        UNRESOLVABLE_PATH = /[(),\s]/
        private_constant :UNRESOLVABLE_PATH

        # Refuses a rule that calls a method the grammar lacks, such as `value.between?(100, 599)`.
        # It would parse as a `lookup` of an attribute that cannot exist and fail on first dispatch.
        #
        # @raise [Bluebook::DSL::Malformed] if a `lookup` path contains a parenthesis, comma or
        #   space
        def refuse_unresolvable_lookups!(ast, owner:, word:)
          return ast if Hecks::Bluebook::MetaValidator.shadow_parsing? # frozen era text is history

          each_node(ast) do |node|
            expression = unresolvable_path(node)
            next unless expression

            raise DSL::Malformed, unresolvable_message(owner, word, expression)
          end
          ast
        end

        # @param node [Hash] one AST node
        # @return [String, nil] the node's dotted path when it is a `lookup` the language cannot
        #   resolve, else `nil`
        def unresolvable_path(node)
          return unless node["op"] == "lookup" && node["path"].is_a?(::Array)

          expression = node["path"].join(".")
          expression if expression.match?(UNRESOLVABLE_PATH)
        end

        # @return [String] the refusal for a rule that calls a method the grammar lacks
        def unresolvable_message(owner, word, expression)
          "#{owner}'s #{word} uses #{expression.inspect}, which the expression language " \
            "cannot evaluate — it is not an attribute, and it is not a method the language " \
            "supports. Spell the test with comparisons and `&&`/`||` instead, such as " \
            "`value >= 100 && value <= 599` in place of `value.between?(100, 599)`"
        end

        # Every name a rule resolves at its root: the first segment of each `lookup` path, unique.
        def lookup_heads(ast)
          heads = []
          each_node(ast) do |node|
            heads << node["path"].first.to_s if node["op"] == "lookup" && node["path"].is_a?(::Array)
          end
          heads.uniq
        end

        # Visits `node` and every Hash nested inside it, depth-first.
        def each_node(node, &block)
          case node
          when ::Hash
            yield node
            node.each_value { |child| each_node(child, &block) }
          when ::Array
            node.each { |child| each_node(child, &block) }
          end
        end

        # Emits the JSON form of one boolean-position Evaluator node.
        def emit_bool(node)
          _, emitter = Emitters::BOOL.find { |klass, _| node.is_a?(klass) }
          return emitter.call(node) if emitter

          raise "unhandled evaluator node #{node.class} — no JSON rendering exists for it " \
                "(lib/hecks/bluebook/expression/ast_json.rb#emit_bool)"
        end

        # Emits the JSON form of one comparison operator.
        def emit_comparison(comparator)
          { "less_than" => comparator.compares_less_than, "equal" => comparator.compares_equal, "negated" => comparator.negated }
        end

        # Mirrors `expr_emitter.rb`'s `emit_include`: no target can represent a literal-array
        # haystack in `include`, so it is rewritten to an or of equalities at emission.
        EQ = Evaluator::OPERATORS.find { |op| op.symbol == "==" }
        private_constant :EQ

        # Emits one `include` node; an empty literal haystack is `false`.
        def emit_include(node)
          return emit_literal_include(node) if node.haystack.is_a?(Resolver::ArrayLiteral)

          { "op" => "include", "haystack" => emit_resolver(node.haystack), "needle" => emit_resolver(node.needle) }
        end

        # @param node [Evaluator::Include] an `include` over a literal-array haystack
        # @return [Hash] an or of equalities over the elements, or `false` for none
        def emit_literal_include(node)
          return { "op" => "bool", "value" => false } if node.haystack.elements.empty?

          equalities = node.haystack.elements.map { |element| emit_equality(node.needle, element) }
          equalities.reduce { |left, right| { "op" => "or", "left" => left, "right" => right } }
        end

        # @return [Hash] the `compare` node for `needle == element`
        def emit_equality(needle, element)
          { "op" => "compare", "cmp" => emit_comparison(EQ), "left" => emit_resolver(needle),
            "right" => emit_resolver(element) }
        end

        # One case arm per Resolver node type, kept in `Emitters::RESOLVER` so exhaustiveness
        # shows at a glance.
        def emit_resolver(node)
          _, emitter = Emitters::RESOLVER.find { |klass, _| node.is_a?(klass) }
          return emitter.call(node) if emitter

          raise "unhandled resolver node #{node.class} — no JSON rendering exists for it " \
                "(lib/hecks/bluebook/expression/ast_json.rb#emit_resolver)"
        end
      end
    end
  end
end
