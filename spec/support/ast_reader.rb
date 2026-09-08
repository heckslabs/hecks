# THE INVERSE OF `Expression::AstJson` — reads the `"op"`-tagged JSON a
# rule row carries as `ast` back into the SAME `Evaluator`/`Resolver`
# node Structs `Evaluator.parse` builds from `canonical`, so a spec can
# prove the structured form carries the whole meaning: interpreting the
# rebuilt tree must answer exactly what interpreting the parsed text
# answers, for every expression the bounded-exhaustive generator can
# spell.
#
# SPEC-ONLY, ON PURPOSE. Nothing in `lib/` reads `ast` yet — the Ruby
# runtime still parses `canonical` — and this file exists precisely to
# pin that the day it does, nothing can change. It is written as the
# obvious mirror of `ast_json.rb`'s two walkers, arm for arm, so a new
# op there is a new arm here and the roster spec fails until it lands.
#
# One deliberate asymmetry, inherited: `AstJson` rewrites a LITERAL-array
# `.include?` into an OR of equalities (see `emit_include`), so reading
# never produces an `Include` over an `ArrayLiteral`. Evaluation is
# unchanged by that rewrite, which is exactly what the equivalence spec
# checks.
module AstReader
  module_function

  E = Hecks::Bluebook::Expression::Evaluator
  R = Hecks::Bluebook::Expression::Resolver

  def read_predicate(json) = read_bool(json)

  def read_bool(json)
    case json.fetch("op")
    when "or"      then E::Or.new(left: read_bool(json["left"]), right: read_bool(json["right"]))
    when "and"     then E::And.new(left: read_bool(json["left"]), right: read_bool(json["right"]))
    when "not"     then E::Not.new(node: read_bool(json["expr"]))
    when "compare"
      E::Compare.new(operator: operator(json["cmp"]), left: read_resolver(json["left"]), right: read_resolver(json["right"]))
    when "include" then E::Include.new(haystack: read_resolver(json["haystack"]), needle: read_resolver(json["needle"]))
    else E::Resolve.new(expr: read_resolver(json))
    end
  end

  # The comparator algebra travels as its three-flag triple; the
  # `Operator` carrying that exact triple is the one `parse` would have
  # chosen, because the roster (`expression/projection.json`) holds one
  # symbol per triple.
  def operator(cmp)
    E::OPERATORS.find do |op|
      op.compares_less_than == cmp.fetch("less_than") &&
        op.compares_equal == cmp.fetch("equal") &&
        op.negated == cmp.fetch("negated")
    end or raise "no comparison operator has the triple #{cmp.inspect}"
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity -- one arm per
  # AstJson op is the point; splitting the case would hide the roster.
  def read_resolver(json)
    recv = -> { read_resolver(json["receiver"]) }
    case json.fetch("op")
    when "int"   then R::IntegerLiteral.new(value: json["value"])
    when "float" then R::FloatLiteral.new(value: json["value"])
    when "str"   then R::StringLiteral.new(value: json["value"])
    when "bool"  then R::BoolLiteral.new(value: json["value"])
    when "nil"   then R::NilLiteral.new
    when "array" then R::ArrayLiteral.new(elements: json["elements"].map { |e| read_resolver(e) })
    when "lookup" then R::Lookup.new(path: json["path"].join("."))
    when "add"    then R::Addition.new(left: read_resolver(json["left"]), right: read_resolver(json["right"]))
    when "sign_test"
      op = operator(json["cmp"])
      R::SignTest.new(operator: op, test: sign_test_name(op), receiver: recv.call)
    when "empty"  then R::Empty.new(receiver: recv.call)
    when "to_s"   then R::ToS.new(receiver: recv.call)
    when "modulo" then R::Modulo.new(receiver: recv.call, divisor: read_resolver(json["divisor"]))
    when "size"   then R::Size.new(receiver: recv.call)
    when "first"  then R::First.new(receiver: recv.call)
    when "last"   then R::Last.new(receiver: recv.call)
    when "block_predicate"
      R::BlockPredicate.new(mode: json["mode"].to_sym, receiver: recv.call, param: json["param"],
                            predicate: read_bool(json["predicate"]))
    when "find"
      R::Find.new(receiver: recv.call, param: json["param"], predicate: read_bool(json["predicate"]), path: json["path"])
    when "matches_regex" then R::MatchesRegex.new(receiver: recv.call, pattern: json["pattern"], flags: json["flags"])
    when "presence"      then R::Presence.new(receiver: recv.call, negated: json["negated"])
    when "assignment"    then R::Assignment.new(receiver: recv.call, negated: json["negated"])
    when "split"         then R::Split.new(receiver: recv.call, separator: json["separator"])
    when "starts_with"   then R::StartsWith.new(receiver: recv.call, substring: json["substring"])
    when "ends_with"     then R::EndsWith.new(receiver: recv.call, substring: json["substring"])
    else raise "no reader handles op #{json['op'].inspect} — add an arm before AstJson can emit it"
    end
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

  # `SignTest#test` is only wording (the refusal names it); the triple is
  # what evaluates. Recover the spelling from the vocabulary so a rebuilt
  # node refuses with the same message the parsed one would.
  def sign_test_name(operator)
    R::SIGN_TEST_OPERATORS.key(operator.symbol) || operator.symbol
  end
end
