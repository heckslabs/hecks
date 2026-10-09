require_relative "evaluator"
require_relative "resolver"

module Hecks
  module Bluebook
    module Expression
      # Raised for an operator `AstReader` has no arm for.
      class UnhandledOp < RuntimeError; end

      # The inverse of `AstJson`: reads a rule row's `"op"`-tagged `ast` back into the
      # `Evaluator`/`Resolver` nodes, so dispatch evaluates a rule without re-parsing its text.
      module AstReader
        module_function

        # Arm for arm with `AstJson`: a new op there fails spec/expression_ast_spec.rb until added
        # here.
        # A literal-array `.include?` is emitted as an or of equalities, so it never reads back as
        # an `Include` over an `ArrayLiteral`; evaluation is unchanged.

        # Reads a whole predicate's `"op"`-tagged JSON back into its AST.
        def read_predicate(json) = read_bool(json)

        # Reads one boolean/comparison node, recursing into its own children.
        def read_bool(json)
          case json.fetch("op")
          when "or"      then read_pair(Evaluator::Or, json)
          when "and"     then read_pair(Evaluator::And, json)
          when "not"     then Evaluator::Not.new(node: read_bool(json["expr"]))
          when "compare" then read_compare(json)
          when "include"
            Evaluator::Include.new(haystack: read_resolver(json["haystack"]), needle: read_resolver(json["needle"]))
          else Evaluator::Resolve.new(expr: read_resolver(json))
          end
        end

        # @param klass [Class] `Evaluator::Or` or `Evaluator::And`
        # @param json [Hash] the node's `"left"` and `"right"` boolean children
        # @return [Object] the node `klass` builds over them
        def read_pair(klass, json) = klass.new(left: read_bool(json["left"]), right: read_bool(json["right"]))

        # @param json [Hash] a `"compare"` node
        # @return [Evaluator::Compare] its operator and both resolver sides
        def read_compare(json)
          Evaluator::Compare.new(operator: operator(json["cmp"]),
                                 left: read_resolver(json["left"]), right: read_resolver(json["right"]))
        end

        # The roster (`expression/projection.json`) holds one symbol per flag triple,
        # so the triple identifies the operator `parse` would have chosen.
        def operator(cmp)
          Evaluator::OPERATORS.find do |op|
            op.compares_less_than == cmp.fetch("less_than") &&
              op.compares_equal == cmp.fetch("equal") &&
              op.negated == cmp.fetch("negated")
          end or raise UnhandledOp, "no comparison operator has the triple #{cmp.inspect}"
        end

        # The readers `read_resolver` tries in turn; each answers `nil` for an op it does not own.
        RESOLVER_READERS = [:read_literal, :read_collection, :read_arithmetic, :read_receiver_only,
                            :read_text_test, :read_presence, :read_block].freeze

        # Reads one dotted/arithmetic leaf node, recursing into its own children.
        def read_resolver(json)
          op = json.fetch("op")
          RESOLVER_READERS.each do |reader|
            node = public_send(reader, json)
            return node if node
          end
          raise UnhandledOp, "no reader handles op #{op.inspect} — add an arm before AstJson can emit it"
        end

        # @param json [Hash] a resolver node
        # @return [Object, nil] the literal it spells, or `nil` when it is not a literal
        def read_literal(json)
          case json["op"]
          when "int"   then Resolver::IntegerLiteral.new(value: json["value"])
          when "float" then Resolver::FloatLiteral.new(value: json["value"])
          when "str"   then Resolver::StringLiteral.new(value: json["value"])
          when "bool"  then Resolver::BoolLiteral.new(value: json["value"])
          when "nil"   then Resolver::NilLiteral.new
          end
        end

        def read_binary(node_class, json) = node_class.new(left: read_resolver(json["left"]), right: read_resolver(json["right"]))

        # @param json [Hash] a resolver node
        # @return [Object, nil] the array or lookup it spells, or `nil` for any other op
        def read_collection(json)
          case json["op"]
          when "array"  then Resolver::ArrayLiteral.new(elements: json["elements"].map { |e| read_resolver(e) })
          when "lookup" then Resolver::Lookup.new(path: json["path"].join("."))
          end
        end

        # @param json [Hash] a resolver node
        # @return [Object, nil] the sum, remainder or sign test it spells, or `nil` for any other op
        def read_arithmetic(json)
          case json["op"]
          when "add"    then read_binary(Resolver::Addition, json)
          when "sub"    then read_binary(Resolver::Subtraction, json)
          when "mul"    then read_binary(Resolver::Multiplication, json)
          when "div"    then read_binary(Resolver::Division, json)
          when "modulo" then Resolver::Modulo.new(receiver: receiver(json), divisor: read_resolver(json["divisor"]))
          when "sign_test"
            op = operator(json["cmp"])
            Resolver::SignTest.new(operator: op, test: sign_test_name(op), receiver: receiver(json))
          end
        end

        # @param json [Hash] a resolver node
        # @return [Object, nil] the node over its receiver alone, or `nil` for any other op
        def read_receiver_only(json)
          case json["op"]
          when "empty" then Resolver::Empty.new(receiver: receiver(json))
          when "to_s"  then Resolver::ToS.new(receiver: receiver(json))
          when "size"  then Resolver::Size.new(receiver: receiver(json))
          when "first" then Resolver::First.new(receiver: receiver(json))
          when "last"  then Resolver::Last.new(receiver: receiver(json))
          when "strip" then Resolver::Strip.new(receiver: receiver(json), side: json["side"].to_sym)
          end
        end

        # @param json [Hash] a resolver node
        # @return [Object, nil] the text test it spells, or `nil` for any other op
        def read_text_test(json)
          case json["op"]
          when "matches_regex"
            Resolver::MatchesRegex.new(receiver: receiver(json), pattern: json["pattern"], flags: json["flags"])
          when "split"         then Resolver::Split.new(receiver: receiver(json), separator: json["separator"])
          when "starts_with"   then Resolver::StartsWith.new(receiver: receiver(json), substring: json["substring"])
          when "ends_with"     then Resolver::EndsWith.new(receiver: receiver(json), substring: json["substring"])
          end
        end

        # @param json [Hash] a resolver node
        # @return [Object, nil] the presence or assignment test it spells, or `nil` for any other op
        def read_presence(json)
          case json["op"]
          when "presence"   then Resolver::Presence.new(receiver: receiver(json), negated: json["negated"])
          when "assignment" then Resolver::Assignment.new(receiver: receiver(json), negated: json["negated"])
          end
        end

        # @param json [Hash] a resolver node
        # @return [Object, nil] the block-taking node it spells, or `nil` for any other op
        def read_block(json)
          case json["op"]
          when "block_predicate"
            Resolver::BlockPredicate.new(mode: json["mode"].to_sym, receiver: receiver(json), param: json["param"],
                                         predicate: read_bool(json["predicate"]))
          when "find"
            Resolver::Find.new(receiver: receiver(json), param: json["param"],
                               predicate: read_bool(json["predicate"]), path: json["path"])
          end
        end

        # @return [Object] the resolver node under `json`'s `"receiver"`
        def receiver(json) = read_resolver(json["receiver"])

        # `SignTest#test` is only refusal wording; recovering it keeps a rebuilt node's message
        # identical to the parsed one's.
        def sign_test_name(operator) = Resolver::SIGN_TEST_OPERATORS.key(operator.symbol) || operator.symbol
      end
    end
  end
end
