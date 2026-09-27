require "spec_helper"
require "hecks/fuzzing/bounded_exhaustive_expressions"

# Every well-typed expression up to depth 3, checked against the evaluator; see
# `Hecks::Fuzzing::BoundedExhaustiveExpressions`. Fast and deterministic, so it runs by default.
#
# Sampling-based fuzzing rarely produces the nested, chained or bracketed shapes that
# exposed parsing bugs in `match_call`, `match_include` and `top_level_index`.
RSpec.describe "the expression sublanguage, exhaustively, for every well-typed expression up to depth 3" do
  BEE = Hecks::Fuzzing::BoundedExhaustiveExpressions

  it "generates a real, bounded, non-trivial set — not zero, not degenerate" do
    predicates = BEE.all_predicates
    expect(predicates.size).to be_between(500, 20_000)
    expect(predicates.uniq.size).to eq(predicates.size)
  end

  it "never raises anything other than EvaluationError for any well-typed expression up to depth 3" do
    crashes = BEE.all_predicates.filter_map do |expr|
      result = BEE.check(expr)
      { expr: expr, error: result[:error] } unless result[:ok]
    end

    message = crashes.map { |c| "#{c[:expr]}\n  -> #{c[:error].class}: #{c[:error].message}" }.join("\n")
    expect(crashes).to be_empty, "#{crashes.size} well-typed expression(s) raised something other than " \
                                 "EvaluationError — a real crash this generator exists to catch:\n#{message}"
  end

  # Every name the generator references is declared in its own `synthetic_state`, so a
  # "cannot resolve" refusal means a silent misparse that failed safe, not a missing attribute.
  it "never refuses with \"cannot resolve\" — every name here is one this generator itself declared" do
    unresolved = BEE.all_predicates.filter_map do |expr|
      result = BEE.check(expr)
      { expr: expr, message: result[:message] } if result[:result] == :refused && result[:message]&.start_with?("cannot resolve")
    end

    message = unresolved.map { |u| "#{u[:expr]}\n  -> #{u[:message]}" }.join("\n")
    expect(unresolved).to be_empty, "#{unresolved.size} well-typed expression(s) refused with \"cannot " \
                                    "resolve\" — every name this generator produces is declared in its own " \
                                    "synthetic_state, so this is a strong signal of a silent misparse, not a " \
                                    "genuine absent-attribute refusal:\n#{message}"
  end

  it "at least one third of the generated set actually SUCCEEDS (a real answer, not just a refusal) — " \
     "a property nothing can ever hold is decoration" do
    results = BEE.all_predicates.map { |expr| BEE.check(expr)[:result] }
    successes = results.count { |r| r != :refused }
    expect(successes).to be > (results.size / 3)
  end
end
