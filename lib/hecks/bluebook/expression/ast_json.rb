require_relative "evaluator"
require_relative "resolver"

module Hecks
  module Bluebook
    module Expression
      # Walks the Evaluator/Resolver AST and emits JSON-serializable Hashes tagged by `"op"`.
      # Lives in core because rust/host cannot link the kernel crate and interprets this from ir.json.
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
                  "#{owner}'s #{word} matches against #{node['pattern'].inspect}, which uses a " \
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
        # @raise [Bluebook::DSL::Malformed] if a `lookup` path contains a parenthesis, comma or space
        def refuse_unresolvable_lookups!(ast, owner:, word:)
          return ast if Hecks::Bluebook::MetaValidator.shadow_parsing? # frozen era text is history

          each_node(ast) do |node|
            next unless node["op"] == "lookup" && node["path"].is_a?(::Array)

            expression = node["path"].join(".")
            next unless expression.match?(UNRESOLVABLE_PATH)

            raise DSL::Malformed,
                  "#{owner}'s #{word} uses #{expression.inspect}, which the expression language " \
                  "cannot evaluate — it is not an attribute, and it is not a method the language " \
                  "supports. Spell the test with comparisons and `&&`/`||` instead, such as " \
                  "`value >= 100 && value <= 599` in place of `value.between?(100, 599)`"
          end
          ast
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
          case node
          when Evaluator::Or  then { "op" => "or", "left" => emit_bool(node.left), "right" => emit_bool(node.right) }
          when Evaluator::And then { "op" => "and", "left" => emit_bool(node.left), "right" => emit_bool(node.right) }
          when Evaluator::Not then { "op" => "not", "expr" => emit_bool(node.node) }
          when Evaluator::Compare
            { "op" => "compare", "cmp" => emit_comparison(node.operator),
              "left" => emit_resolver(node.left), "right" => emit_resolver(node.right) }
          when Evaluator::Include
            emit_include(node)
          when Evaluator::Resolve
            emit_resolver(node.expr)
          else
            raise "unhandled evaluator node #{node.class} — no JSON rendering exists for it " \
                  "(lib/hecks/bluebook/expression/ast_json.rb#emit_bool)"
          end
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
          return { "op" => "include", "haystack" => emit_resolver(node.haystack), "needle" => emit_resolver(node.needle) } \
            unless node.haystack.is_a?(Resolver::ArrayLiteral)

          return { "op" => "bool", "value" => false } if node.haystack.elements.empty?

          equalities = node.haystack.elements.map do |element|
            { "op" => "compare", "cmp" => emit_comparison(EQ), "left" => emit_resolver(node.needle),
"right" => emit_resolver(element) }
          end
          equalities.reduce { |left, right| { "op" => "or", "left" => left, "right" => right } }
        end

        # One case arm per Resolver node type, kept in one method so exhaustiveness shows at a glance.
        # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        def emit_resolver(node)
          case node
          when Resolver::IntegerLiteral then { "op" => "int", "value" => node.value }
          when Resolver::FloatLiteral   then { "op" => "float", "value" => node.value }
          when Resolver::StringLiteral  then { "op" => "str", "value" => node.value }
          when Resolver::BoolLiteral    then { "op" => "bool", "value" => node.value }
          when Resolver::NilLiteral     then { "op" => "nil" }
          # Segments, as `find.path` has, so a reader need not split a dotted string.
          when Resolver::Lookup         then { "op" => "lookup", "path" => node.path.split(".") }
          when Resolver::Addition       then { "op" => "add", "left" => emit_resolver(node.left), "right" => emit_resolver(node.right) }
          when Resolver::SignTest
            { "op" => "sign_test", "cmp" => emit_comparison(node.operator), "receiver" => emit_resolver(node.receiver) }
          when Resolver::Empty  then { "op" => "empty", "receiver" => emit_resolver(node.receiver) }
          when Resolver::ToS    then { "op" => "to_s", "receiver" => emit_resolver(node.receiver) }
          when Resolver::Modulo then { "op" => "modulo", "receiver" => emit_resolver(node.receiver), "divisor" => emit_resolver(node.divisor) }
          when Resolver::Size   then { "op" => "size", "receiver" => emit_resolver(node.receiver) }
          when Resolver::BlockPredicate
            { "op" => "block_predicate", "mode" => node.mode.to_s, "receiver" => emit_resolver(node.receiver),
              "param" => node.param.to_s, "predicate" => emit_bool(node.predicate) }
          when Resolver::Find
            { "op" => "find", "receiver" => emit_resolver(node.receiver), "param" => node.param.to_s,
              "predicate" => emit_bool(node.predicate), "path" => node.path.map(&:to_s) }
          when Resolver::ArrayLiteral
            { "op" => "array", "elements" => node.elements.map { |element| emit_resolver(element) } }
          when Resolver::MatchesRegex
            { "op" => "matches_regex", "receiver" => emit_resolver(node.receiver), "pattern" => node.pattern,
"flags" => node.flags }
          when Resolver::Presence
            { "op" => "presence", "receiver" => emit_resolver(node.receiver), "negated" => node.negated }
          when Resolver::Assignment
            { "op" => "assignment", "receiver" => emit_resolver(node.receiver), "negated" => node.negated }
          when Resolver::Split
            { "op" => "split", "receiver" => emit_resolver(node.receiver), "separator" => node.separator }
          when Resolver::StartsWith
            { "op" => "starts_with", "receiver" => emit_resolver(node.receiver), "substring" => node.substring }
          when Resolver::EndsWith
            { "op" => "ends_with", "receiver" => emit_resolver(node.receiver), "substring" => node.substring }
          when Resolver::First then { "op" => "first", "receiver" => emit_resolver(node.receiver) }
          when Resolver::Last  then { "op" => "last", "receiver" => emit_resolver(node.receiver) }
          else
            raise "unhandled resolver node #{node.class} — no JSON rendering exists for it " \
                  "(lib/hecks/bluebook/expression/ast_json.rb#emit_resolver)"
          end
        end
      end
    end
  end
end
