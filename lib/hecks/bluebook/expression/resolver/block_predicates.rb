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

        module_function

        # Every suffix that opens a `{ |x| ... }` block; `.find` builds a `Find`, not a mode.
        BLOCK_OPENER_SUFFIXES = (BLOCK_PREDICATE_MODES.keys + ["find"]).freeze

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
          pattern = /\A(.+?)\.(#{BLOCK_OPENER_SUFFIXES.map { |suffix| Regexp.escape(suffix) }.join('|')})\s*\{\s*\|(\w+)\|\s*/m
          header = expr.match(pattern)
          return nil unless header

          receiver_text = header[1]
          suffix = header[2]
          param = header[3]
          body_start = header.end(0)
          body_end = matching_brace(expr, body_start)
          return nil unless body_end

          predicate = Evaluator.parse(expr[body_start...body_end].strip)

          if suffix == "find"
            trailing = expr[(body_end + 1)..].strip
            return nil unless trailing.empty? || trailing.start_with?(".")

            Find.new(receiver: parse(receiver_text), param: param, predicate: predicate,
                     path: trailing.empty? ? [] : trailing[1..].split("."))
          else
            return nil unless expr[(body_end + 1)..].strip.empty?

            BlockPredicate.new(mode: BLOCK_PREDICATE_MODES.fetch(suffix), receiver: parse(receiver_text),
                               param: param, predicate: predicate)
          end
        end

        # The index of the `}` closing the `{` the caller's header match already consumed
        # (depth starts at 1). Quote-aware, so a `}` inside a quoted substring never counts.
        #
        # @param expr [String] the text to scan
        # @param start [Integer] the index just after the opening `{`, where depth is 1
        # @return [Integer, nil] the index of the matching `}`, or nil if `expr` runs
        #   out before depth returns to 0
        def matching_brace(expr, start)
          depth = 1
          quote = nil
          index = start
          while index < expr.length
            char = expr[index]
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            elsif char == "{"
              depth += 1
            elsif char == "}"
              depth -= 1
              return index if depth.zero?
            end
            index += 1
          end
          nil
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
