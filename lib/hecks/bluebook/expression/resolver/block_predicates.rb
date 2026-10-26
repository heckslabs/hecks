# Block-predicate and `.find` suffixes of the `Resolver` leaf grammar, split out of resolver.rb
# to stay under Metrics/ModuleLength. Uses the nested `module` form so constants resolve as there.
module Hecks
  module Bluebook
    module Expression
      # Reopens `Resolver` (see resolver.rb) for the block-predicate/find suffixes.
      module Resolver
        # `receiver.all? { |x| PREDICATE }` / `.any?` / `.none?`. `predicate` is a parsed
        # `Evaluator` ast (not a Resolver ast), evaluated once per element with the block
        # parameter bound to that element.
        BlockPredicate = Struct.new(:mode, :receiver, :param, :predicate, keyword_init: true)

        # Maps each block-predicate suffix to the aggregate mode it applies.
        BLOCK_PREDICATE_MODES = {
          "all?"  => :all,
          "any?"  => :any,
          "none?" => :none
        }.freeze

        # `receiver.find { |x| PREDICATE }` with an optional trailing dotted `path` projected
        # through the found element (`legs.find { |l| ... }.next_load_location`).
        # Shares `param`/`predicate` with `BlockPredicate` so `interpret_with_element` serves both.
        Find = Struct.new(:receiver, :param, :predicate, :path, keyword_init: true)

        # `receiver.sum { |x| EXPRESSION }`: the total of a number worked out for each element,
        # as `items.sum { |i| i.quantity * i.price }`. Shares `param`/`predicate` with `Find`,
        # though the block holds a number, not a test; an empty list totals 0.
        Sum = Struct.new(:receiver, :param, :predicate, keyword_init: true)

        module_function

        # Every suffix that opens a `{ |x| ... }` block; `.find` builds a `Find` and `.sum` a `Sum`,
        # not a mode.
        BLOCK_OPENER_SUFFIXES = (BLOCK_PREDICATE_MODES.keys + %w[find sum]).freeze

        # Receiver text, suffix and block parameter of an opener, up to the first body character.
        BLOCK_OPENER_PATTERN =
          /\A(.+?)\.(#{BLOCK_OPENER_SUFFIXES.map { |suffix| Regexp.escape(suffix) }.join("|")})\s*\{\s*\|(\w+)\|\s*/m

        # `.all?`/`.any?`/`.none?`/`.find` — matched last among the suffix rules, before the
        # `Lookup` catch-all, since a block's predicate can contain almost any leaf expression.
        #
        # One regex scans all four suffixes together so the leftmost opener wins; scanning per
        # suffix would match a `.find` nested inside an outer `.any?` block first.
        # `matching_brace` finds the closing `}`; `.find` may then carry a trailing dotted `path`,
        # every other suffix must end at the brace.
        #
        # @param expr [String] the leaf expression text to parse
        # @return [Find, BlockPredicate, nil] the parsed node, or nil when `expr` does
        #   not open a `.all?`/`.any?`/`.none?`/`.find` block, or its brace never closes
        def parse_block_opener(expr)
          header = expr.match(BLOCK_OPENER_PATTERN)
          return nil unless header

          body_end = matching_brace(expr, header.end(0))
          return nil unless body_end

          predicate = Evaluator.parse(expr[header.end(0)...body_end].strip)
          rest = expr[(body_end + 1)..].strip
          return find_node(header, predicate, rest) if header[2] == "find"
          return sum_node(header, predicate, rest) if header[2] == "sum"

          block_predicate_node(header, predicate, rest)
        end

        # @param header [MatchData] the opener match: receiver text, suffix, block parameter
        # @param predicate [Object] the parsed block body, a number rather than a test
        # @param rest [String] the text after the closing brace
        # @return [Sum, nil] the node, or nil unless the block ends `expr`
        def sum_node(header, predicate, rest)
          return nil unless rest.empty?

          Sum.new(receiver: parse(header[1]), param: header[3], predicate: predicate)
        end

        # @param header [MatchData] the opener match: receiver text, suffix, block parameter
        # @param predicate [Object] the parsed block body
        # @param rest [String] the text after the closing brace
        # @return [Find, nil] the node, or nil unless `rest` is empty or a dotted path
        def find_node(header, predicate, rest)
          return nil unless rest.empty? || rest.start_with?(".")

          Find.new(receiver: parse(header[1]), param: header[3], predicate: predicate,
                   path: rest.empty? ? [] : rest[1..].split("."))
        end

        # @param header [MatchData] the opener match: receiver text, suffix, block parameter
        # @param predicate [Object] the parsed block body
        # @param rest [String] the text after the closing brace
        # @return [BlockPredicate, nil] the node, or nil unless the block ends `expr`
        def block_predicate_node(header, predicate, rest)
          return nil unless rest.empty?

          BlockPredicate.new(mode: BLOCK_PREDICATE_MODES.fetch(header[2]), receiver: parse(header[1]),
                             param: header[3], predicate: predicate)
        end

        # `.all?`/`.any?`/`.none?` over an already-interpreted `collection`: runs the
        # per-element predicate and aggregates by `node.mode`.
        #
        # @param node [BlockPredicate] the parsed `.all?`/`.any?`/`.none?` node
        # @param collection [Object] the interpreted receiver, expected to be an Array
        # @param state [Hash{Symbol => Object}] the record's own current state
        # @param attrs [Hash{Symbol => Object}] the command's own bound arguments
        # @return [Boolean] whether the collection satisfies `node.mode`
        # @raise [EvaluationError] if `collection` is not an Array
        def evaluate_block_predicate(node, collection, state, attrs)
          raise EvaluationError, "#{node.mode}? expects a list, got #{describe(collection)}" unless collection.is_a?(Array)

          outcomes = collection.map { |element| interpret_with_element(node, element, state, attrs) }

          case node.mode
          when :all  then outcomes.all?
          when :any  then outcomes.any?
          when :none then outcomes.none?
          end
        end

        # Interprets `node.predicate` with `node.param` bound to `element`, for that call only.
        # `attrs` wins over `state`, so the bound name shadows any same-named field.
        #
        # @param node [BlockPredicate, Find]
        # @param element [Object] the collection element to bind
        # @param state [Hash{Symbol => Object}] the record's current state
        # @param attrs [Hash{Symbol => Object}] the command's bound arguments
        # @return [Object] the predicate's value for `element`
        # @raise [EvaluationError] if `node.predicate` refuses to evaluate
        def interpret_with_element(node, element, state, attrs)
          Evaluator.interpret(node.predicate, state, attrs.merge(node.param.to_sym => element))
        end

        # `.sum { |x| EXPRESSION }` — the block's number for every element, added up with the same
        # 64-bit overflow check an addition has. An empty list is 0.
        #
        # @param node [Sum] the parsed `.sum` node
        # @param collection [Object] the interpreted receiver, expected to be an Array
        # @param state [Hash{Symbol => Object}] the record's own current state
        # @param attrs [Hash{Symbol => Object}] the command's own bound arguments
        # @return [Integer, Float] the total
        # @raise [EvaluationError] if `collection` is not an Array, or a term is not a number
        def summed_of(node, collection, state, attrs)
          raise EvaluationError, "sum expects a list, got #{describe(collection)}" unless collection.is_a?(Array)

          collection.reduce(0) { |total, element| add(total, term_of(node, element, state, attrs)) }
        end

        # What `node`'s block works out for `element`: the value of a plain expression, or, for a
        # block that is a test, its true or false, which the addition then refuses.
        #
        # @param node [Sum] the parsed `.sum` node
        # @param element [Object] the collection element to bind
        # @param state [Hash{Symbol => Object}] the record's current state
        # @param attrs [Hash{Symbol => Object}] the command's bound arguments
        # @return [Object] the block's value for `element`
        def term_of(node, element, state, attrs)
          bound = attrs.merge(node.param.to_sym => element)
          body = node.predicate
          return unwrap_scalar(interpret(body.expr, state, bound)) if body.is_a?(Evaluator::Resolve)

          Evaluator.interpret(body, state, bound)
        end

        # `.find { |x| PREDICATE }` — the first element the predicate accepts, then `node.path`
        # walked through it. A miss yields nil rather than raising: no match is a normal outcome.
        #
        # @param node [Find] the parsed `.find` node
        # @param collection [Object] the interpreted receiver, expected to be an Array
        # @param state [Hash{Symbol => Object}] the record's own current state
        # @param attrs [Hash{Symbol => Object}] the command's own bound arguments
        # @return [Object, nil] the found element (or `node.path` projected through it),
        #   or nil when no element matches or a `path` segment does not resolve
        # @raise [EvaluationError] if `collection` is not an Array
        def found_of(node, collection, state, attrs)
          raise EvaluationError, "find expects a list, got #{describe(collection)}" unless collection.is_a?(Array)

          found = collection.find { |element| interpret_with_element(node, element, state, attrs) }
          return unwrap_scalar(found) if node.path.empty?
          return nil if found.nil?

          unwrap_scalar(walk_path(found, node.path))
        end
      end
    end
  end
end
