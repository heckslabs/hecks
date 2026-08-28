require "spec_helper"
require "hecks/fuzzing/bounded_exhaustive_expressions"

# Phase 7 (equivalence-gap plan) — see `Hecks::Fuzzing::
# BoundedExhaustiveExpressions`'s own header for the full design (why
# type-directed, what "proven" means here precisely, what it does and
# does not claim). Deterministic and fast (a few thousand cases, well
# under a second) — this runs in the default suite, no `io:`/`fuzzing:`
# tag needed.
#
# Found four real, previously-undiscovered parsing bugs live, all fixed
# alongside this file (see each one's own comment at its fix site):
#   - `Resolver#match_call` (nested AND chained `.modulo(...)`)
#   - `Evaluator#match_include` (nested `.include?(...)`)
#   - `Evaluator#top_level_index` / `Resolver#split_addition` (`[`/`]`
#     never counted toward bracket depth, so an array literal containing
#     its own top-level `+`/comparison mis-split the ENCLOSING expression)
# None had any real corpus precedent (grep, all four) — sampling-based
# fuzzing essentially never manufactures the specific nested/chained/
# bracketed shapes that triggered them, which is exactly why exhaustive,
# type-directed generation exists as its own, separate technique here
# rather than a wider `bin/fuzz` seed count.
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

  # A NARROWER, STRONGER assertion than "no crash": every "cannot
  # resolve X — no such attribute or argument" refusal is ITSELF a
  # finding for this specific generator (unlike a real fuzzer with
  # deliberately-absent attributes) — every name this generator ever
  # references is declared, with a value, in its own `synthetic_state`
  # (`SYNTHETIC_ATTRS`/`ARRAY_ELEMENT_TYPE`), so a genuinely well-typed,
  # correctly-generated expression should NEVER fail to resolve a name.
  # When one does, the FAR more likely explanation is a silent misparse
  # that happened to fail safe into a real `EvaluationError` rather than
  # a raw crash — exactly how all three of this file's own real findings
  # first surfaced (a garbled `Lookup` path quoting fragment text no
  # author ever wrote, not a genuine absent-attribute refusal).
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

  it "at least one third of the generated set actually SUCCEEDS (a real answer, not just a refusal) — a property nothing can ever hold is decoration" do
    results = BEE.all_predicates.map { |expr| BEE.check(expr)[:result] }
    successes = results.count { |r| r != :refused }
    expect(successes).to be > (results.size / 3)
  end
end
