require_relative "evaluator"
require_relative "resolver"

module Hecks
  module Bluebook
    module Expression
      # THE INVERSE OF `AstJson` — reads the `"op"`-tagged JSON a rule row
      # carries as `ast` back into the SAME `Evaluator`/`Resolver` node
      # Structs `Evaluator.parse` builds from `canonical`. This is how the
      # runtime evaluates a rule without re-parsing its text: the one
      # parse happened at DSL-build time, behind `AstJson`; dispatch walks
      # the structured form (`Evaluator.call_rule`), and `canonical` stays
      # what it always displayed as — text for humans and refusal wording.
      #
      # Written as the obvious mirror of `ast_json.rb`'s two walkers, arm
      # for arm, so a new op there is a new arm here and
      # spec/expression_ast_spec.rb's roster contract fails until it
      # lands. Promoted from spec/support once the runtime switched —
      # the spec proved the round trip first, then the runtime adopted it.
      #
      # One deliberate asymmetry, inherited: `AstJson` rewrites a
      # LITERAL-array `.include?` into an OR of equalities (see
      # `emit_include`), so reading never produces an `Include` over an
      # `ArrayLiteral`. Evaluation is unchanged by that rewrite, which is
      # exactly what the equivalence spec pins.
      module AstReader
        module_function

        def read_predicate(json) = read_bool(json)

        def read_bool(json)
          case json.fetch("op")
          when "or"      then Evaluator::Or.new(left: read_bool(json["left"]), right: read_bool(json["right"]))
          when "and"     then Evaluator::And.new(left: read_bool(json["left"]), right: read_bool(json["right"]))
          when "not"     then Evaluator::Not.new(node: read_bool(json["expr"]))
          when "compare"
            Evaluator::Compare.new(operator: operator(json["cmp"]),
                                   left: read_resolver(json["left"]), right: read_resolver(json["right"]))
          when "include"
            Evaluator::Include.new(haystack: read_resolver(json["haystack"]), needle: read_resolver(json["needle"]))
          else Evaluator::Resolve.new(expr: read_resolver(json))
          end
        end

        # The comparator algebra travels as its three-flag triple; the
        # `Operator` carrying that exact triple is the one `parse` would
        # have chosen, because the roster (`expression/projection.json`)
        # holds one symbol per triple.
        def operator(cmp)
          Evaluator::OPERATORS.find do |op|
            op.compares_less_than == cmp.fetch("less_than") &&
              op.compares_equal == cmp.fetch("equal") &&
              op.negated == cmp.fetch("negated")
          end or raise "no comparison operator has the triple #{cmp.inspect}"
        end

        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity -- one arm
        # per AstJson op is the point; splitting the case would hide the roster.
        def read_resolver(json)
          recv = -> { read_resolver(json["receiver"]) }
          case json.fetch("op")
          when "int"   then Resolver::IntegerLiteral.new(value: json["value"])
          when "float" then Resolver::FloatLiteral.new(value: json["value"])
          when "str"   then Resolver::StringLiteral.new(value: json["value"])
          when "bool"  then Resolver::BoolLiteral.new(value: json["value"])
          when "nil"   then Resolver::NilLiteral.new
          when "array" then Resolver::ArrayLiteral.new(elements: json["elements"].map { |e| read_resolver(e) })
          when "lookup" then Resolver::Lookup.new(path: json["path"].join("."))
          when "add"    then Resolver::Addition.new(left: read_resolver(json["left"]), right: read_resolver(json["right"]))
          when "sign_test"
            op = operator(json["cmp"])
            Resolver::SignTest.new(operator: op, test: sign_test_name(op), receiver: recv.call)
          when "empty"  then Resolver::Empty.new(receiver: recv.call)
          when "to_s"   then Resolver::ToS.new(receiver: recv.call)
          when "modulo" then Resolver::Modulo.new(receiver: recv.call, divisor: read_resolver(json["divisor"]))
          when "size"   then Resolver::Size.new(receiver: recv.call)
          when "first"  then Resolver::First.new(receiver: recv.call)
          when "last"   then Resolver::Last.new(receiver: recv.call)
          when "block_predicate"
            Resolver::BlockPredicate.new(mode: json["mode"].to_sym, receiver: recv.call, param: json["param"],
                                         predicate: read_bool(json["predicate"]))
          when "find"
            Resolver::Find.new(receiver: recv.call, param: json["param"],
                               predicate: read_bool(json["predicate"]), path: json["path"])
          when "matches_regex" then Resolver::MatchesRegex.new(receiver: recv.call, pattern: json["pattern"],
                                                               flags: json["flags"])
          when "presence"      then Resolver::Presence.new(receiver: recv.call, negated: json["negated"])
          when "assignment"    then Resolver::Assignment.new(receiver: recv.call, negated: json["negated"])
          when "split"         then Resolver::Split.new(receiver: recv.call, separator: json["separator"])
          when "starts_with"   then Resolver::StartsWith.new(receiver: recv.call, substring: json["substring"])
          when "ends_with"     then Resolver::EndsWith.new(receiver: recv.call, substring: json["substring"])
          else raise "no reader handles op #{json['op'].inspect} — add an arm before AstJson can emit it"
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

        # `SignTest#test` is only wording (the refusal names it); the
        # triple is what evaluates. Recover the spelling from the
        # vocabulary so a rebuilt node refuses with the same message the
        # parsed one would.
        def sign_test_name(operator)
          Resolver::SIGN_TEST_OPERATORS.key(operator.symbol) || operator.symbol
        end
      end
    end
  end
end
